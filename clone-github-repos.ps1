param(
    [Parameter(Mandatory = $false)]
    [string]$User,

    [Parameter(Mandatory = $false)]
    [string]$Org,

    [Parameter(Mandatory = $false)]
    [string]$Token = $env:GITHUB_TOKEN,

    [Parameter(Mandatory = $false)]
    [string]$Destination = ".",

    [Parameter(Mandatory = $false)]
    [switch]$UseSsh,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeArchived,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeForks,

    [Parameter(Mandatory = $false)]
    [switch]$AvoidBlocking,

    [Parameter(Mandatory = $false)]
    [int]$MinDelaySeconds = 1,

    [Parameter(Mandatory = $false)]
    [int]$MaxDelaySeconds = 3,

    [Parameter(Mandatory = $false)]
    [int]$MaxApiRetries = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Get-GitHubHeaders {
    param([string]$AuthToken)

    $headers = @{
        "Accept" = "application/vnd.github+json"
        "User-Agent" = "github-repo-cloner-script"
    }

    if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
        $headers["Authorization"] = "Bearer $AuthToken"
    }

    return $headers
}

function Wait-PoliteDelay {
    param([string]$Reason)

    if (-not $AvoidBlocking) {
        return
    }

    $delay = Get-Random -Minimum $MinDelaySeconds -Maximum ($MaxDelaySeconds + 1)
    Write-Info "Polite mode: waiting ${delay}s before $Reason"
    Start-Sleep -Seconds $delay
}

function Get-RetryDelaySeconds {
    param(
        [object]$Exception,
        [int]$Attempt
    )

    $defaultDelay = [Math]::Min(60, [int][Math]::Pow(2, $Attempt))
    $response = $null

    try {
        $response = $Exception.Response
    } catch {
        return $defaultDelay
    }

    if (-not $response) {
        return $defaultDelay
    }

    $headers = $response.Headers
    if (-not $headers) {
        return $defaultDelay
    }

    $retryAfterRaw = $headers["Retry-After"]
    if (-not [string]::IsNullOrWhiteSpace($retryAfterRaw)) {
        $retryAfter = 0
        if ([int]::TryParse($retryAfterRaw, [ref]$retryAfter) -and $retryAfter -gt 0) {
            return $retryAfter
        }
    }

    $remaining = $headers["X-RateLimit-Remaining"]
    $resetRaw = $headers["X-RateLimit-Reset"]

    if ($remaining -eq "0" -and -not [string]::IsNullOrWhiteSpace($resetRaw)) {
        $resetEpoch = 0
        if ([int]::TryParse($resetRaw, [ref]$resetEpoch) -and $resetEpoch -gt 0) {
            $currentEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $untilReset = [Math]::Max(1, $resetEpoch - $currentEpoch + 2)
            return [int]$untilReset
        }
    }

    return $defaultDelay
}

function Invoke-GitHubApiWithRetry {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [int]$Retries = 5
    )

    $attempt = 1

    while ($true) {
        try {
            return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get
        } catch {
            if (-not $AvoidBlocking) {
                throw
            }

            $statusCode = 0
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode.value__
            } catch {
                $statusCode = 0
            }

            $isRetryable = $statusCode -eq 0 -or $statusCode -eq 403 -or $statusCode -eq 429 -or $statusCode -eq 500 -or $statusCode -eq 502 -or $statusCode -eq 503 -or $statusCode -eq 504
            if (-not $isRetryable -or $attempt -ge $Retries) {
                throw
            }

            $delay = Get-RetryDelaySeconds -Exception $_.Exception -Attempt $attempt
            if ($delay -lt $MinDelaySeconds) {
                $delay = $MinDelaySeconds
            }

            Write-Warn "GitHub API request failed (status: $statusCode). Retrying in ${delay}s (attempt $attempt/$Retries)..."
            Start-Sleep -Seconds $delay
            $attempt++
        }
    }
}

function Get-ReposPaged {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers
    )

    $repos = @()
    $page = 1

    while ($true) {
        $url = "$BaseUrl&per_page=100&page=$page"
        Write-Info "Fetching page ${page}: $url"

        Wait-PoliteDelay -Reason "GitHub API call"
        $pageRepos = Invoke-GitHubApiWithRetry -Uri $url -Headers $Headers -Retries $MaxApiRetries

        if (-not $pageRepos -or $pageRepos.Count -eq 0) {
            break
        }

        $repos += $pageRepos
        $page++
    }

    return $repos
}

if (($User -and $Org) -or (-not $User -and -not $Org)) {
    Write-Err "Provide exactly one of -User or -Org."
    exit 1
}

if ($AvoidBlocking -and ($MinDelaySeconds -lt 1 -or $MaxDelaySeconds -lt $MinDelaySeconds)) {
    Write-Err "When using -AvoidBlocking, ensure MinDelaySeconds >= 1 and MaxDelaySeconds >= MinDelaySeconds."
    exit 1
}

if ($MaxApiRetries -lt 1) {
    Write-Err "MaxApiRetries must be at least 1."
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Err "Git is not installed or not available in PATH."
    exit 1
}

$headers = Get-GitHubHeaders -AuthToken $Token

# Ensure destination exists and resolve it to an absolute path
$resolvedDestination = Resolve-Path -Path $Destination -ErrorAction SilentlyContinue
if (-not $resolvedDestination) {
    New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    $resolvedDestination = Resolve-Path -Path $Destination
}
$destinationPath = $resolvedDestination.Path

if ($User) {
    # Public repos for any user
    $endpoint = "https://api.github.com/users/$User/repos?type=all&sort=full_name"

    # If token belongs to this user, switch to /user/repos to include private repos as well
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        try {
            Wait-PoliteDelay -Reason "GitHub identity check"
            $me = Invoke-GitHubApiWithRetry -Uri "https://api.github.com/user" -Headers $headers -Retries $MaxApiRetries
            if ($me.login -eq $User) {
                $endpoint = "https://api.github.com/user/repos?visibility=all&affiliation=owner,collaborator,organization_member&sort=full_name"
                Write-Info "Authenticated as '$($me.login)'; private repositories accessible to this account will be included."
            }
        } catch {
            Write-Warn "Could not verify authenticated user; continuing with public user endpoint. $_"
        }
    }

    Write-Info "Listing repositories for user '$User'..."
} else {
    $endpoint = "https://api.github.com/orgs/$Org/repos?type=all&sort=full_name"
    Write-Info "Listing repositories for organization '$Org'..."
}

try {
    $repos = Get-ReposPaged -BaseUrl $endpoint -Headers $headers
} catch {
    Write-Err "Failed to fetch repositories from GitHub API. $_"
    exit 1
}

if (-not $IncludeArchived) {
    $repos = $repos | Where-Object { -not $_.archived }
}

if (-not $IncludeForks) {
    $repos = $repos | Where-Object { -not $_.fork }
}

if (-not $repos -or $repos.Count -eq 0) {
    Write-Warn "No repositories found after filtering."
    exit 0
}

Write-Info "Found $($repos.Count) repositories to clone."

$cloned = 0
$skipped = 0
$failed = 0

foreach ($repo in $repos) {

    $repoUrl = if ($UseSsh) { $repo.ssh_url } else { $repo.clone_url }
    $repoDir = Join-Path -Path $destinationPath -ChildPath $repo.name

    if (Test-Path -Path $repoDir) {
        Write-Info "Updating $($repo.full_name) (directory exists: $repoDir)"
        try {
            Push-Location $repoDir
            Wait-PoliteDelay -Reason "git fetch"
            git fetch --all --tags | Out-Null
            git pull --all | Out-Null
            # Get all remote branches
            $remoteBranches = git branch -r | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^origin/' -and $_ -notmatch '/HEAD$' }
            $localBranches = git branch --list | ForEach-Object { $_.Trim().Replace('* ', '') }
            foreach ($remoteBranch in $remoteBranches) {
                $branchName = $remoteBranch -replace '^origin/', ''
                if ($localBranches -notcontains $branchName) {
                    Write-Info "Checking out branch '$branchName' for $($repo.full_name)"
                    git branch $branchName $remoteBranch | Out-Null
                }
            }
            Pop-Location
            $skipped++
        } catch {
            Write-Warn "Failed to update $($repo.full_name): $_"
            $failed++
        }
        continue
    }

    Write-Info "Cloning $($repo.full_name) -> $repoDir"

    try {
        Wait-PoliteDelay -Reason "git clone"
        git clone --origin origin $repoUrl $repoDir | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "git clone exited with code $LASTEXITCODE"
        }

        # Fetch all tags and all remotes
        Write-Info "Fetching all tags and branches for $($repo.full_name)"
        Push-Location $repoDir
        git fetch --all --tags | Out-Null

        # Get all remote branches
        $remoteBranches = git branch -r | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^origin/' -and $_ -notmatch '/HEAD$' }
        $localBranches = git branch --list | ForEach-Object { $_.Trim().Replace('* ', '') }

        foreach ($remoteBranch in $remoteBranches) {
            $branchName = $remoteBranch -replace '^origin/', ''
            if ($localBranches -notcontains $branchName) {
                Write-Info "Checking out branch '$branchName' for $($repo.full_name)"
                git branch $branchName $remoteBranch | Out-Null
            }
        }
        Pop-Location

        $cloned++
    } catch {
        Write-Warn "Failed to clone $($repo.full_name): $_"
        $failed++
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Cloned : $cloned"
Write-Host "Skipped: $skipped"
Write-Host "Failed : $failed"
