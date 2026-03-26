# GitHub Repo Cloner Usage

This guide explains how to use the scripts to clone all repositories from a GitHub user or organization.

## Requirements

- **Windows:** PowerShell 5.1+, Git
- **Linux/Mac:** Bash, curl, jq, Git
- Optional: GitHub personal access token in `GITHUB_TOKEN` for private repositories

---

## PowerShell (Windows)

### Basic Commands

Clone all repositories for a user:

```powershell
.\scripts\clone-github-repos.ps1 -User your-username -Destination .
```

Clone all repositories for an organization:

```powershell
.\scripts\clone-github-repos.ps1 -Org your-org -Destination .
```

### Avoid GitHub Blocking

Enable polite mode to reduce the chance of API abuse/rate-limit blocking.
This mode adds randomized delays and retries API calls with backoff.

```powershell
.\scripts\clone-github-repos.ps1 -User your-username -Destination . -AvoidBlocking
```

Tune pacing and retries:

```powershell
.\scripts\clone-github-repos.ps1 -Org your-org -Destination . -AvoidBlocking -MinDelaySeconds 2 -MaxDelaySeconds 5 -MaxApiRetries 8
```

---

## Bash (Linux/Mac)

### Basic Commands

Clone all repositories for a user:

```bash
./scripts/clone-github-repos.sh --user your-username --destination .
```

Clone all repositories for an organization:

```bash
./scripts/clone-github-repos.sh --org your-org --destination .
```

### Avoid GitHub Blocking

Enable polite mode to reduce the chance of API abuse/rate-limit blocking.
This mode adds randomized delays and retries API calls with backoff.

```bash
./scripts/clone-github-repos.sh --user your-username --destination . --avoid-blocking
```

Tune pacing and retries:

```bash
./scripts/clone-github-repos.sh --org your-org --destination . --avoid-blocking --min-delay 2 --max-delay 5 --max-api-retries 8
```

---

## Authentication (for private repos)

Set token for current shell session:

```powershell
$env:GITHUB_TOKEN = "your_token_here"
```

Then run the script normally.

## Common Options

Use SSH clone URLs instead of HTTPS:

```powershell
.\scripts\clone-github-repos.ps1 -User your-username -Destination . -UseSsh
```

Include archived repositories:

```powershell
.\scripts\clone-github-repos.ps1 -Org your-org -Destination . -IncludeArchived
```

Include forks:

```powershell
.\scripts\clone-github-repos.ps1 -Org your-org -Destination . -IncludeForks
```

Include both archived repos and forks:

```powershell
.\scripts\clone-github-repos.ps1 -Org your-org -Destination . -IncludeArchived -IncludeForks
```

## Notes

- The script paginates GitHub API results automatically.
- Existing local folders are skipped.
- Exactly one of `-User` or `-Org` must be provided.
