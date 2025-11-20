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
   - The workflow uses:

     ```yaml
     env:
       GITHUB_TOKEN: ${{ secrets.GH_PAT }}
     ```

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
output/ is where the reports are written. You can commit .gitignore to keep it out of Git.

3. Configuration
3.1. Organization name
The script and workflow use the ORG environment variable.

Examples:

Local:

bash
Copy code
export ORG=my-org-name
./scripts/scan_codeql_health.sh
GitHub Actions:

yaml
Copy code
env:
  ORG: your-org-name
3.2. Exclude list
File: config/exclude_repos.txt

One repo name per line (no org/ prefix).

Lines starting with # are treated as comments.

Empty lines are ignored.

Example:

text
Copy code
# Repos we don't care about:
legacy-service
playground-repo
experimental-codeql-test
The script will label these repos as EXCLUDED and not scan them for workflows.

3.3. Auth options
Local – Option 1: gh auth login
bash
Copy code
gh auth login
# Select GitHub.com, HTTPS, and follow prompts

# Then simply run
ORG=my-org ./scripts/scan_codeql_health.sh
Local – Option 2: Environment token
bash
Copy code
export GITHUB_TOKEN=ghp_xxx   # or GH_TOKEN
ORG=my-org ./scripts/scan_codeql_health.sh
The script uses gh auth status to verify authentication before scanning.

GitHub Actions
Create a Personal Access Token (classic or fine-grained) with at least:

read:org

repo

Save it as a repo or org secret, e.g. GH_PAT.

The workflow uses:

yaml
Copy code
env:
  GITHUB_TOKEN: ${{ secrets.GH_PAT }}
GitHub’s built-in ${{ github.token }} may not have enough scope to list all org repos depending on your setup, so a PAT is safer.

4. Running locally
4.1. First run
Clone or create the repo with the script and config, then:

bash
Copy code
chmod +x scripts/scan_codeql_health.sh

# Using gh auth login
gh auth login

# Set org and run
export ORG=my-org-name
./scripts/scan_codeql_health.sh
Or:

bash
Copy code
GITHUB_TOKEN=ghp_xxx ORG=my-org-name ./scripts/scan_codeql_health.sh
4.2. Outputs
After running, you’ll get:

output/codeql_report.csv
Example:

csv
Copy code
org,repo,status,codeql_workflows,failing_workflows,last_failure_url,excluded
my-org,service-a,OK,2,0,,false
my-org,service-b,FAILING,1,1,https://github.com/my-org/service-b/actions/runs/123456789,false
my-org,legacy-service,EXCLUDED,0,0,,true
my-org,small-tool,NO_CODEQL,0,0,,false
output/codeql_report.json
Array of objects, e.g.:

json
Copy code
[
  {
    "org": "my-org",
    "repo": "service-a",
    "status": "OK",
    "codeql_workflows": 2,
    "failing_workflows": 0,
    "last_failure_url": null,
    "excluded": false
  },
  {
    "org": "my-org",
    "repo": "service-b",
    "status": "FAILING",
    "codeql_workflows": 1,
    "failing_workflows": 1,
    "last_failure_url": "https://github.com/my-org/service-b/actions/runs/123456789",
    "excluded": false
  }
]
output/codeql_summary.txt
Text summary, e.g.:

text
Copy code
===== CodeQL Health Summary =====
Org:              my-org
Total repos:      50
Scanned repos:    47
Excluded repos:   3
OK repos:         40
FAILING repos:    5
NO_CODEQL repos:  2

Failing repos:
- my-org/service-b (last_failure_url: https://github.com/my-org/service-b/actions/runs/123456789)
- my-org/service-c (last_failure_url: n/a)
You can load the CSV into Excel, or use jq on the JSON.

5. GitHub Actions automation
The workflow file .github/workflows/codeql-health-scan.yml:

Runs:

On manual trigger (workflow_dispatch).

On a daily schedule (cron).

Steps:

Checkout repo.

Ensure gh and jq are installed.

Run scripts/scan_codeql_health.sh.

Compute failing repo count from JSON.

Upload reports as artifacts.

Send optional notifications.

5.1. Setting up secrets
Go to Settings → Secrets and variables → Actions and add:

GH_PAT – Personal Access Token for GitHub API.

(Optional) TEAMS_WEBHOOK_URL – Incoming webhook URL for a Teams channel.

(Optional) AWS-related:

AWS_SNS_TOPIC_ARN

AWS_REGION

AWS_ACCESS_KEY_ID

AWS_SECRET_ACCESS_KEY

5.2. Running the workflow
Manual: In the GitHub UI → Actions → CodeQL Health Scan → Run workflow.

Scheduled: It will run automatically at the defined cron time.

You’ll see artifacts named codeql-health-report with the CSV/JSON/summary files.

6. Notifications
6.1. Microsoft Teams
If TEAMS_WEBHOOK_URL is configured and there is at least one failing repo:

The workflow sends a simple JSON payload:

json
Copy code
{
  "text": "CodeQL health report for org: my-org\n\n...summary text..."
}
Teams will display this as a message in the configured channel.

You can later evolve this to use Adaptive Cards for richer formatting, but the current setup is intentionally simple.

6.2. AWS SNS
If AWS_SNS_TOPIC_ARN is set and there are failing repos:

The workflow publishes the text summary to that SNS topic:

text
Copy code
Subject: CodeQL Health Report - org: my-org
Message: <content of codeql_summary.txt>
From SNS, you can:

Send emails.

Trigger Lambdas.

Forward to other systems.

7. How the scanner detects failures
For each non-excluded repo, the script:

Lists all Actions workflows.

Filters workflows whose name or path matches codeql (case-insensitive).

For each such workflow:

Retrieves up to 10 runs.

Takes the latest run where status == "completed".

If:

No runs at all, or

No completed runs, or

conclusion != "success"

→ this workflow is counted as failing.

The repo is then classified as:

FAILING – if at least one CodeQL workflow is failing.

OK – if there are CodeQL workflows and none are failing.

NO_CODEQL – if no CodeQL workflows are detected.

EXCLUDED – if listed in exclude_repos.txt.

This handles both default and advanced CodeQL setups, and any combination of the two.

8. Troubleshooting
Q: The script says gh is not authenticated.

Run:

bash
Copy code
gh auth login
or:

bash
Copy code
export GITHUB_TOKEN=ghp_xxx
Q: I get permission errors listing org repos.

Ensure your PAT has read:org and repo scopes.

In GitHub Actions, make sure GH_PAT is set and used as GITHUB_TOKEN in env.

Q: Some CodeQL workflows are not detected.

This scanner matches workflows whose name/path contains codeql.

If your org uses a completely different naming scheme with no codeql token:

Update the filter in scripts/scan_codeql_health.sh where it does test("codeql"; "i") and adjust it to your patterns.

Optionally extend it to inspect workflow YAML for github/codeql-action.

That’s the full setup: script, workflow, config, and documentation.
You can now drop this into a tooling repo, wire up secrets, and start getting daily org-wide CodeQL health reports plus Teams/AWS alerts.

makefile
Copy code
::contentReference[oaicite:0]{index=0}











