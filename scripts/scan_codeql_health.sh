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
