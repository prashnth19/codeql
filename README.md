# CodeQL Health Monitor

This repo provides a simple automation to **monitor CodeQL health across all repositories in a GitHub organization**.

It:

- Scans all non-archived repos in an org (with an optional exclude list).
- Detects workflows that run **CodeQL** (default and advanced).
- Checks the *latest completed run* for each CodeQL workflow.
- Classifies each repo as:
  - `OK` – Has CodeQL workflows and all latest runs succeed.
  - `FAILING` – Has at least one CodeQL workflow whose latest run is not successful.
  - `NO_CODEQL` – No CodeQL workflows detected.
  - `EXCLUDED` – Explicitly skipped by config.
- Outputs:
  - `output/codeql_report.csv` – CSV summary.
  - `output/codeql_report.json` – JSON summary.
  - `output/codeql_summary.txt` – Human-readable text summary.
- Integrates with **GitHub Actions**, and can notify:
  - **Microsoft Teams** (via webhook).
  - **AWS SNS** (for fan-out to email, Lambda, etc.).

---

## 1. Requirements

### 1.1. Tools

On any machine (including GitHub Actions runner), you need:

- [`gh` – GitHub CLI](https://cli.github.com/)
- [`jq` – JSON CLI processor](https://stedolan.github.io/jq/)

The GitHub Actions workflow installs them automatically if they are missing.

### 1.2. Permissions

You need a token that can:

- Read repos in your org (`read:org`, `repo` scope is usually enough).

Used in two ways:

1. **Local usage**
   - `gh auth login` (interactive) **or**
   - `export GITHUB_TOKEN=ghp_xxx` (PAT) before running the script.

2. **GitHub Actions**
   - Store your PAT in a secret, e.g. `GH_PAT`.
   - The workflow uses `GITHUB_TOKEN: ${{ secrets.GH_PAT }}`.

---

## 2. Directory structure

Recommended structure for this tool:

```text
codeql-health-monitor/
  scripts/
    scan_codeql_health.sh
  config/
    exclude_repos.txt
  output/
    .gitignore              # optional, ignore everything here
  .github/
    workflows/
      codeql-health-scan.yml
  README.md
