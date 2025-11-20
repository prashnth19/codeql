1. scripts/scan_codeql_health.sh

Create this file: scripts/scan_codeql_health.sh

#!/usr/bin/env bash
set -euo pipefail

# CodeQL health scanner
# - Scans all repos in a GitHub org
# - Detects workflows running CodeQL (default + advanced)
# - Checks latest completed run for each CodeQL workflow
# - Classifies each repo as: OK / FAILING / NO_CODEQL
# - Outputs CSV + JSON and a human-readable summary
#
# Dependencies:
#   - gh (GitHub CLI)
#   - jq
#
# Auth:
#   - Uses gh auth (gh auth login), or
#   - Uses GITHUB_TOKEN / GH_TOKEN env vars

#######################################
# Configuration / Input
#######################################

ORG="${ORG:-}"                      # ORG env var (recommended)
EXCLUDE_FILE="${EXCLUDE_FILE:-config/exclude_repos.txt}"
OUTPUT_DIR="${OUTPUT_DIR:-output}"

if [[ $# -ge 1 && -z "$ORG" ]]; then
  ORG="$1"
fi

if [[ -z "$ORG" ]]; then
  echo "ERROR: GitHub org not specified." >&2
  echo "Set ORG env var or pass as first argument, e.g.:" >&2
  echo "  ORG=my-org ./scripts/scan_codeql_health.sh" >&2
  echo "  ./scripts/scan_codeql_health.sh my-org" >&2
  exit 1
fi

#######################################
# Pre-flight checks
#######################################

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found. Install from https://cli.github.com/" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found. Install jq and try again." >&2
  exit 1
fi

# Check auth
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated." >&2
  echo "Use one of:" >&2
  echo "  1) Set GITHUB_TOKEN / GH_TOKEN env variable" >&2
  echo "  2) Run: gh auth login" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

CSV_FILE="$OUTPUT_DIR/codeql_report.csv"
JSON_TMP="$OUTPUT_DIR/codeql_report_tmp.jsonl"
JSON_FILE="$OUTPUT_DIR/codeql_report.json"
SUMMARY_FILE="$OUTPUT_DIR/codeql_summary.txt"

# Initialize outputs
echo "org,repo,status,codeql_workflows,failing_workflows,last_failure_url,excluded" > "$CSV_FILE"
: > "$JSON_TMP"
: > "$SUMMARY_FILE"

#######################################
# Load exclude list
#######################################

declare -A EXCLUDED_REPOS

if [[ -f "$EXCLUDE_FILE" ]]; then
  while IFS= read -r line; do
    repo_name="$(echo "$line" | sed 's/#.*$//' | xargs)"  # strip comments & trim
    if [[ -n "$repo_name" ]]; then
      EXCLUDED_REPOS["$repo_name"]=1
    fi
  done < "$EXCLUDE_FILE"
fi

#######################################
# Counters / stats
#######################################

total_repos=0
scanned_repos=0
excluded_repos=0
ok_repos=0
failing_repos=0
no_codeql_repos=0

#######################################
# Helper: check if repo is excluded
#######################################
is_excluded_repo() {
  local repo_name="$1"
  if [[ -n "${EXCLUDED_REPOS[$repo_name]+x}" ]]; then
    return 0
  else
    return 1
  fi
}

#######################################
# Fetch all repos in org
#######################################

echo "Fetching repositories for org '$ORG'..." >&2

REPO_NAMES=$(
  gh api -H "Accept: application/vnd.github+json" \
    "/orgs/$ORG/repos?per_page=100&type=all" --paginate \
    | jq -r '.[] | select(.archived == false) | .name' \
    || true
)

if [[ -z "$REPO_NAMES" ]]; then
  echo "WARNING: No repositories found for org '$ORG' or API returned nothing." >&2
fi

#######################################
# Main loop: per repo
#######################################

for REPO in $REPO_NAMES; do
  total_repos=$((total_repos + 1))

  if is_excluded_repo "$REPO"; then
    excluded_repos=$((excluded_repos + 1))
    # Still write a row as excluded (optional)
    echo "$ORG,$REPO,EXCLUDED,0,0,,true" >> "$CSV_FILE"
    echo "{\"org\":\"$ORG\",\"repo\":\"$REPO\",\"status\":\"EXCLUDED\",\"codeql_workflows\":0,\"failing_workflows\":0,\"last_failure_url\":null,\"excluded\":true}" >> "$JSON_TMP"
    continue
  fi

  scanned_repos=$((scanned_repos + 1))

  echo "Scanning $ORG/$REPO..." >&2

  # List workflows
  WF_JSON=$(
    gh api -H "Accept: application/vnd.github+json" \
      "/repos/$ORG/$REPO/actions/workflows" --paginate 2>/dev/null \
      || echo ""
  )

  if [[ -z "$WF_JSON" || "$WF_JSON" == "null" ]]; then
    # No workflows at all -> No CodeQL
    no_codeql_repos=$((no_codeql_repos + 1))
    echo "$ORG,$REPO,NO_CODEQL,0,0,,false" >> "$CSV_FILE"
    echo "{\"org\":\"$ORG\",\"repo\":\"$REPO\",\"status\":\"NO_CODEQL\",\"codeql_workflows\":0,\"failing_workflows\":0,\"last_failure_url\":null,\"excluded\":false}" >> "$JSON_TMP"
    continue
  fi

  # Filter workflows that look like CodeQL:
  #  - name contains "codeql" (case-insensitive)
  #  - OR path contains "codeql"
  CODEQL_WFS=$(
    echo "$WF_JSON" \
      | jq -c '.workflows[] |
        select(
          (.name | test("codeql"; "i")) or
          (.path | test("codeql"; "i"))
        )' \
      || true
  )

  if [[ -z "$CODEQL_WFS" ]]; then
    # No CodeQL workflows found
    no_codeql_repos=$((no_codeql_repos + 1))
    echo "$ORG,$REPO,NO_CODEQL,0,0,,false" >> "$CSV_FILE"
    echo "{\"org\":\"$ORG\",\"repo\":\"$REPO\",\"status\":\"NO_CODEQL\",\"codeql_workflows\":0,\"failing_workflows\":0,\"last_failure_url\":null,\"excluded\":false}" >> "$JSON_TMP"
    continue
  fi

  # We have at least one CodeQL workflow
  total_codeql_workflows=0
  failing_workflows=0
  last_failure_url=""

  while IFS= read -r WF; do
    [[ -z "$WF" ]] && continue

    WF_ID=$(echo "$WF" | jq -r '.id')
    WF_NAME=$(echo "$WF" | jq -r '.name')
    WF_PATH=$(echo "$WF" | jq -r '.path')

    total_codeql_workflows=$((total_codeql_workflows + 1))

    # Get latest completed run
    RUN_JSON=$(
      gh api -H "Accept: application/vnd.github+json" \
        "/repos/$ORG/$REPO/actions/workflows/$WF_ID/runs?per_page=10" 2>/dev/null \
        || echo ""
    )

    if [[ -z "$RUN_JSON" || "$RUN_JSON" == "null" ]]; then
      # No runs -> treat as failure-like (misconfigured)
      failing_workflows=$((failing_workflows + 1))
      # No URL to store
      continue
    fi

    LAST_RUN=$(
      echo "$RUN_JSON" \
        | jq -c '.workflow_runs[] | select(.status == "completed")' \
        | head -n 1 \
        || true
    )

    if [[ -z "$LAST_RUN" ]]; then
      # No completed runs -> treat this as failure-like
      failing_workflows=$((failing_workflows + 1))
      continue
    fi

    LAST_STATUS=$(echo "$LAST_RUN" | jq -r '.status')       # "completed"
    LAST_CONCLUSION=$(echo "$LAST_RUN" | jq -r '.conclusion') # success/failure/...
    LAST_URL=$(echo "$LAST_RUN" | jq -r '.html_url')

    if [[ "$LAST_CONCLUSION" != "success" ]]; then
      failing_workflows=$((failing_workflows + 1))
      # Only store first failure URL for summary
      if [[ -z "$last_failure_url" ]]; then
        last_failure_url="$LAST_URL"
      fi
    fi

  done <<< "$CODEQL_WFS"

  # Determine repo status
  repo_status=""
  if [[ "$total_codeql_workflows" -eq 0 ]]; then
    repo_status="NO_CODEQL"
    no_codeql_repos=$((no_codeql_repos + 1))
  else
    if [[ "$failing_workflows" -gt 0 ]]; then
      repo_status="FAILING"
      failing_repos=$((failing_repos + 1))
    else
      repo_status="OK"
      ok_repos=$((ok_repos + 1))
    fi
  fi

  # CSV row
  printf '%s,%s,%s,%d,%d,%s,%s\n' \
    "$ORG" \
    "$REPO" \
    "$repo_status" \
    "$total_codeql_workflows" \
    "$failing_workflows" \
    "${last_failure_url:-}" \
    "false" >> "$CSV_FILE"

  # JSON line
  jq -n --arg org "$ORG" \
        --arg repo "$REPO" \
        --arg status "$repo_status" \
        --arg lfu "$last_failure_url" \
        --argjson tcw "$total_codeql_workflows" \
        --argjson fw "$failing_workflows" \
        '{"org":$org,"repo":$repo,"status":$status,"codeql_workflows":$tcw,"failing_workflows":$fw,"last_failure_url":($lfu|select(. != "") // null),"excluded":false}' \
    >> "$JSON_TMP"

done

#######################################
# Final JSON array + summary
#######################################

jq -s '.' "$JSON_TMP" > "$JSON_FILE"

echo "===== CodeQL Health Summary =====" | tee -a "$SUMMARY_FILE"
echo "Org:              $ORG" | tee -a "$SUMMARY_FILE"
echo "Total repos:      $total_repos" | tee -a "$SUMMARY_FILE"
echo "Scanned repos:    $scanned_repos" | tee -a "$SUMMARY_FILE"
echo "Excluded repos:   $excluded_repos" | tee -a "$SUMMARY_FILE"
echo "OK repos:         $ok_repos" | tee -a "$SUMMARY_FILE"
echo "FAILING repos:    $failing_repos" | tee -a "$SUMMARY_FILE"
echo "NO_CODEQL repos:  $no_codeql_repos" | tee -a "$SUMMARY_FILE"
echo "" | tee -a "$SUMMARY_FILE"

if [[ "$failing_repos" -gt 0 ]]; then
  echo "Failing repos:" | tee -a "$SUMMARY_FILE"
  jq -r '.[] | select(.status=="FAILING") | "- \(.org)/\(.repo) (last_failure_url: \(.last_failure_url // "n/a"))"' "$JSON_FILE" | tee -a "$SUMMARY_FILE"
else
  echo "No failing CodeQL repos detected 🎉" | tee -a "$SUMMARY_FILE"
fi

# If running in GitHub Actions, expose counts as outputs (for notification steps)
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "total_repos=$total_repos"
    echo "scanned_repos=$scanned_repos"
    echo "excluded_repos=$excluded_repos"
    echo "ok_repos=$ok_repos"
    echo "failing_repos=$failing_repos"
    echo "no_codeql_repos=$no_codeql_repos"
  } >> "$GITHUB_OUTPUT"
fi

echo "" >&2
echo "CSV report:   $CSV_FILE" >&2
echo "JSON report:  $JSON_FILE" >&2
echo "Summary file: $SUMMARY_FILE" >&2


Make it executable:

chmod +x scripts/scan_codeql_health.sh

2. config/exclude_repos.txt (example)

Create config/exclude_repos.txt:

# One repo name per line (no org prefix).
# Lines starting with # are comments.

legacy-service
playground-repo
experimental-codeql-test


If this file doesn’t exist, the script just scans everything.

3. GitHub Actions Workflow

Create .github/workflows/codeql-health-scan.yml:

name: CodeQL Health Scan

on:
  workflow_dispatch: {}
  schedule:
    # Every day at 07:00 UTC (adjust as you like)
    - cron: "0 7 * * *"

jobs:
  scan:
    runs-on: ubuntu-latest

    env:
      ORG: your-org-name                    # <-- set your org name here
      GITHUB_TOKEN: ${{ secrets.GH_PAT }}   # Personal access token with read:org, repo
      EXCLUDE_FILE: config/exclude_repos.txt
      OUTPUT_DIR: output
      TEAMS_WEBHOOK_URL: ${{ secrets.TEAMS_WEBHOOK_URL }}          # optional
      AWS_SNS_TOPIC_ARN: ${{ secrets.AWS_SNS_TOPIC_ARN }}          # optional
      AWS_REGION: ${{ secrets.AWS_REGION }}                         # optional
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}          # optional
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}  # optional

    steps:
      - name: Checkout repo
        uses: actions/checkout@v4

      - name: Ensure gh and jq are installed
        run: |
          if ! command -v gh >/dev/null 2>&1; then
            echo "gh CLI not found, installing..."
            type -p curl >/dev/null || (sudo apt update && sudo apt install -y curl)
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
            sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
            sudo apt update
            sudo apt install -y gh
          fi

          if ! command -v jq >/dev/null 2>&1; then
            echo "jq not found, installing..."
            sudo apt update
            sudo apt install -y jq
          fi

      - name: Run CodeQL health scan
        id: scan
        run: |
          ./scripts/scan_codeql_health.sh

      - name: Compute failing repo count from JSON
        id: stats
        run: |
          FAILING_COUNT=$(jq '[.[] | select(.status=="FAILING")] | length' output/codeql_report.json)
          echo "failing_count=$FAILING_COUNT" >> "$GITHUB_OUTPUT"
          echo "Failing repos: $FAILING_COUNT"

      - name: Upload reports as artifacts
        uses: actions/upload-artifact@v4
        with:
          name: codeql-health-report
          path: |
            output/codeql_report.csv
            output/codeql_report.json
            output/codeql_summary.txt
          if-no-files-found: error

      # ---------- Optional: Notify Microsoft Teams ----------
      - name: Notify Microsoft Teams (if failing repos)
        if: ${{ env.TEAMS_WEBHOOK_URL != '' && steps.stats.outputs.failing_count != '0' }}
        run: |
          SUMMARY=$(cat output/codeql_summary.txt)
          # Escape newlines for JSON
          SUMMARY_ESCAPED=$(printf '%s\n' "$SUMMARY" | jq -Rs .)

          # Teams expects a JSON object with 'text'
          PAYLOAD=$(cat <<EOF
          {
            "text": "CodeQL health report for org: $ORG\n\n$(printf '%s' "$SUMMARY" | sed 's/"/\\"/g')"
          }
          EOF
          )

          curl -X POST \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" \
            "$TEAMS_WEBHOOK_URL"

      # ---------- Optional: Notify via AWS SNS ----------
      - name: Publish summary to AWS SNS (if configured)
        if: ${{ env.AWS_SNS_TOPIC_ARN != '' && steps.stats.outputs.failing_count != '0' }}
        run: |
          SUMMARY=$(cat output/codeql_summary.txt)
          aws sns publish \
            --region "$AWS_REGION" \
            --topic-arn "$AWS_SNS_TOPIC_ARN" \
            --subject "CodeQL Health Report - org: $ORG" \
            --message "$SUMMARY"


Adjust org name and secrets according to your environment.

4. README.md

Create README.md in the repo:

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


output/ is where the reports are written. You can commit .gitignore to keep it out of Git.

3. Configuration
3.1. Organization name

The script and workflow use the ORG environment variable.

Examples:

Local:

export ORG=my-org-name
./scripts/scan_codeql_health.sh


GitHub Actions:

env:
  ORG: your-org-name

3.2. Exclude list

File: config/exclude_repos.txt

One repo name per line (no org/ prefix).

Lines starting with # are treated as comments.

Empty lines are ignored.

Example:

# Repos we don't care about:
legacy-service
playground-repo
experimental-codeql-test


The script will label these repos as EXCLUDED and not scan them for workflows.

3.3. Auth options
Local – Option 1: gh auth login
gh auth login
# Select GitHub.com, HTTPS, and follow prompts


Then simply run:

ORG=my-org ./scripts/scan_codeql_health.sh

Local – Option 2: Environment token
export GITHUB_TOKEN=ghp_xxx   # or GH_TOKEN
ORG=my-org ./scripts/scan_codeql_health.sh


The script uses gh auth status to verify authentication before scanning.

GitHub Actions

Create a Personal Access Token (classic or fine-grained) with at least:

read:org

repo

Save it as a repo or org secret, e.g. GH_PAT.

The workflow uses:

env:
  GITHUB_TOKEN: ${{ secrets.GH_PAT }}


GitHub’s built-in ${{ github.token }} may not have enough scope to list all org repos depending on your setup, so PAT is safer.

4. Running locally
4.1. First run

Clone or create the repo with the script and config, then:

chmod +x scripts/scan_codeql_health.sh

# Using gh auth login
gh auth login

# Set org and run
export ORG=my-org-name
./scripts/scan_codeql_health.sh


Or:

GITHUB_TOKEN=ghp_xxx ORG=my-org-name ./scripts/scan_codeql_health.sh

4.2. Outputs

After running, you’ll get:

output/codeql_report.csv
Example:

org,repo,status,codeql_workflows,failing_workflows,last_failure_url,excluded
my-org,service-a,OK,2,0,,false
my-org,service-b,FAILING,1,1,https://github.com/my-org/service-b/actions/runs/123456789,false
my-org,legacy-service,EXCLUDED,0,0,,true
my-org,small-tool,NO_CODEQL,0,0,,false


output/codeql_report.json – array of objects, e.g.:

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


output/codeql_summary.txt – text summary, e.g.:

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

{
  "text": "CodeQL health report for org: my-org\n\n...summary text..."
}


Teams will display this as a message in the configured channel.

You can later evolve this to use Adaptive Cards for richer formatting, but the current setup is intentionally simple.

6.2. AWS SNS

If AWS_SNS_TOPIC_ARN is set and there are failing repos:

The workflow publishes the text summary to that SNS topic:

Subject: CodeQL Health Report - org: my-org
Message: <content of codeql_summary.txt>


From SNS, you can:

Send emails.

Trigger Lambdas.

Forward to other systems.

7. How the scanner detects failures

For each non-excluded repo:

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

Repo is:

FAILING if at least one CodeQL workflow is failing.

OK if there are CodeQL workflows and none are failing.

NO_CODEQL if no CodeQL workflows are detected.

EXCLUDED if listed in exclude_repos.txt.

This handles both default and advanced CodeQL setups, and any combination of the two.

8. Troubleshooting

Q: The script says gh is not authenticated.

Run:

gh auth login


or

export GITHUB_TOKEN=ghp_xxx


Q: I get permission errors listing org repos.

Ensure your PAT has read:org and repo scopes.

In GitHub Actions, make sure GH_PAT is set and used as GITHUB_TOKEN in env.

Q: Some CodeQL workflows are not detected.

This scanner matches workflows whose name/path contains codeql.

If your org uses a completely different naming scheme with no codeql token:

Update the filter in scan_codeql_health.sh where it does test("codeql"; "i") and adjust it to your patterns.

Optionally extend it to inspect workflow YAML for github/codeql-action.

That’s the full setup: script, workflow, config, and documentation.
You can now drop this into a tooling repo, wire up secrets, and start getting daily org-wide CodeQL health reports plus Teams/AWS alerts.
