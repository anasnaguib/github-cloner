# GitHub Repo Cloner

This project provides a PowerShell script to clone all repositories from a GitHub user or organization.

## Features

- Clone all repositories for a user or organization
- Supports authentication for private repositories
- Optionally includes archived and forked repositories
- Polite mode to avoid GitHub API rate limits
- Uses SSH or HTTPS clone URLs
- Automatic pagination of API results
- Skips existing local folders

## Requirements

- PowerShell 5.1 or later
- Git installed and available in PATH
- (Optional) GitHub personal access token for private repositories

## Usage

See [usage.md](usage.md) for detailed instructions and examples.

## Script

- [clone-github-repos.ps1](clone-github-repos.ps1): Main PowerShell script

## License

MIT License
