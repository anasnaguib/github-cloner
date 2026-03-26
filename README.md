# GitHub Repo Cloner

This project provides scripts to clone all repositories from a GitHub user or organization.

## Features

- Clone all repositories for a user or organization
- Supports authentication for private repositories
- Optionally includes archived and forked repositories
- Polite mode to avoid GitHub API rate limits
- Uses SSH or HTTPS clone URLs
- Automatic pagination of API results
- Skips existing local folders
- **Supports both PowerShell (Windows) and Bash (Linux/Mac)**

## Requirements

- **Windows:** PowerShell 5.1 or later
- **Linux/Mac:** Bash, curl, jq, and Git installed and available in PATH
- (Optional) GitHub personal access token for private repositories

## Usage

See [usage.md](usage.md) for detailed instructions and examples for both PowerShell and Bash scripts.

## Scripts

- [clone-github-repos.ps1](clone-github-repos.ps1): PowerShell script for Windows
- [clone-github-repos.sh](clone-github-repos.sh): Bash script for Linux/Mac

## License

MIT License
