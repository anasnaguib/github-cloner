#!/usr/bin/env bash
# clone-github-repos.sh
# Clone all repositories for a GitHub user or organization (Linux/Mac)

set -euo pipefail

usage() {
  echo "Usage: $0 [-u user] [-o org] [-t token] [-d destination] [--ssh] [--include-archived] [--include-forks] [--avoid-blocking] [--min-delay N] [--max-delay N] [--max-api-retries N]"
  echo "  -u, --user                GitHub username (mutually exclusive with --org)"
  echo "  -o, --org                 GitHub organization (mutually exclusive with --user)"
  echo "  -t, --token               GitHub token (or set GITHUB_TOKEN env var)"
  echo "  -d, --destination         Destination directory (default: current)"
  echo "      --ssh                 Use SSH URLs instead of HTTPS"
  echo "      --include-archived    Include archived repositories"
  echo "      --include-forks       Include forked repositories"
  echo "      --avoid-blocking      Enable polite delays to avoid API rate limits"
  echo "      --min-delay N         Minimum delay in seconds (default: 1)"
  echo "      --max-delay N         Maximum delay in seconds (default: 3)"
  echo "      --max-api-retries N   Maximum API retries (default: 5)"
  exit 1
}

# Defaults
USER=""
ORG=""
TOKEN="${GITHUB_TOKEN:-}"
DEST="."
USE_SSH=0
INCLUDE_ARCHIVED=0
INCLUDE_FORKS=0
AVOID_BLOCKING=0
MIN_DELAY=1
MAX_DELAY=3
MAX_API_RETRIES=5

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user) USER="$2"; shift 2;;
    -o|--org) ORG="$2"; shift 2;;
    -t|--token) TOKEN="$2"; shift 2;;
    -d|--destination) DEST="$2"; shift 2;;
    --ssh) USE_SSH=1; shift;;
    --include-archived) INCLUDE_ARCHIVED=1; shift;;
    --include-forks) INCLUDE_FORKS=1; shift;;
    --avoid-blocking) AVOID_BLOCKING=1; shift;;
    --min-delay) MIN_DELAY="$2"; shift 2;;
    --max-delay) MAX_DELAY="$2"; shift 2;;
    --max-api-retries) MAX_API_RETRIES="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown argument: $1"; usage;;
  esac
done

if { [[ -z "$USER" ]] && [[ -z "$ORG" ]]; } || { [[ -n "$USER" ]] && [[ -n "$ORG" ]]; }; then
  echo "Error: Provide exactly one of --user or --org." >&2
  usage
fi

if [[ "$AVOID_BLOCKING" -eq 1 ]]; then
  if [[ "$MIN_DELAY" -lt 1 ]] || [[ "$MAX_DELAY" -lt "$MIN_DELAY" ]]; then
    echo "Error: When using --avoid-blocking, ensure --min-delay >= 1 and --max-delay >= --min-delay." >&2
    exit 1
  fi
fi

if [[ "$MAX_API_RETRIES" -lt 1 ]]; then
  echo "Error: --max-api-retries must be at least 1." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is not installed or not in PATH." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is not installed or not in PATH." >&2
  exit 1
fi

mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)

headers=("-H" "Accept: application/vnd.github+json" "-H" "User-Agent: github-repo-cloner-script")
if [[ -n "$TOKEN" ]]; then
  headers+=("-H" "Authorization: Bearer $TOKEN")
fi

polite_delay() {
  local reason="$1"
  if [[ "$AVOID_BLOCKING" -eq 1 ]]; then
    local delay=$(( RANDOM % (MAX_DELAY - MIN_DELAY + 1) + MIN_DELAY ))
    echo "[INFO] Polite mode: waiting ${delay}s before $reason"
    sleep "$delay"
  fi
}

get_repos_paged() {
  local base_url="$1"
  local page=1
  local repos_json="[]"
  while :; do
    local url="${base_url}&per_page=100&page=$page"
    echo "[INFO] Fetching page $page: $url"
    polite_delay "GitHub API call"
    local resp
    resp=$(curl -sfSL "${headers[@]}" "$url") || {
      echo "[ERROR] Failed to fetch: $url" >&2
      exit 1
    }
    local count
    count=$(echo "$resp" | jq 'length')
    if [[ "$count" -eq 0 ]]; then
      break
    fi
    repos_json=$(jq -s 'add' <(echo "$repos_json") <(echo "$resp"))
    page=$((page+1))
  done
  echo "$repos_json"
}

if [[ -n "$USER" ]]; then
  endpoint="https://api.github.com/users/$USER/repos?type=all&sort=full_name"
  if [[ -n "$TOKEN" ]]; then
    me=$(curl -sfSL "${headers[@]}" "https://api.github.com/user" 2>/dev/null || true)
    login=$(echo "$me" | jq -r '.login // empty')
    if [[ "$login" == "$USER" ]]; then
      endpoint="https://api.github.com/user/repos?visibility=all&affiliation=owner,collaborator,organization_member&sort=full_name"
      echo "[INFO] Authenticated as '$login'; private repositories accessible to this account will be included."
    fi
  fi
  echo "[INFO] Listing repositories for user '$USER'..."
else
  endpoint="https://api.github.com/orgs/$ORG/repos?type=all&sort=full_name"
  echo "[INFO] Listing repositories for organization '$ORG'..."
fi

repos_json=$(get_repos_paged "$endpoint")

if [[ "$INCLUDE_ARCHIVED" -eq 0 ]]; then
  repos_json=$(echo "$repos_json" | jq '[.[] | select(.archived == false)]')
fi
if [[ "$INCLUDE_FORKS" -eq 0 ]]; then
  repos_json=$(echo "$repos_json" | jq '[.[] | select(.fork == false)]')
fi

repo_count=$(echo "$repos_json" | jq 'length')
if [[ "$repo_count" -eq 0 ]]; then
  echo "[WARN] No repositories found after filtering."
  exit 0
fi

echo "[INFO] Found $repo_count repositories to clone."

cloned=0
skipped=0
failed=0

for row in $(echo "$repos_json" | jq -r '.[] | @base64'); do
  _jq() { echo "$row" | base64 --decode | jq -r "$1"; }
  name=$(_jq '.name')
  full_name=$(_jq '.full_name')
  clone_url=$(_jq '.clone_url')
  ssh_url=$(_jq '.ssh_url')
  repo_url="$clone_url"
  if [[ "$USE_SSH" -eq 1 ]]; then
    repo_url="$ssh_url"
  fi
  repo_dir="$DEST/$name"
  if [[ -d "$repo_dir" ]]; then
    echo "[WARN] Skipping $full_name (directory exists: $repo_dir)"
    skipped=$((skipped+1))
    continue
  fi
  echo "[INFO] Cloning $full_name -> $repo_dir"
  polite_delay "git clone"
  if git clone --origin origin "$repo_url" "$repo_dir"; then
    (
      cd "$repo_dir"
      echo "[INFO] Fetching all tags and branches for $full_name"
      git fetch --all --tags
      remote_branches=$(git branch -r | grep '^  origin/' | grep -v '/HEAD$' | sed 's/^  origin\///')
      for branch in $remote_branches; do
        if ! git branch --list | grep -q "^  $branch$"; then
          echo "[INFO] Checking out branch '$branch' for $full_name"
          git branch "$branch" "origin/$branch"
        fi
      done
    )
    cloned=$((cloned+1))
  else
    echo "[WARN] Failed to clone $full_name"
    failed=$((failed+1))
  fi

done

echo
printf "Done.\nCloned : %d\nSkipped: %d\nFailed : %d\n" "$cloned" "$skipped" "$failed"
