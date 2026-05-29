#!/usr/bin/env bash
# Creates a ThousandEyes v7 page-load test and an associated alert rule.
#
# Usage:
#   chmod +x TE_SCRIPTS/create-page-load-and-alert.sh
#   ./TE_SCRIPTS/create-page-load-and-alert.sh "<API_TOKEN>"
#   ./TE_SCRIPTS/create-page-load-and-alert.sh "$TOKEN" ledeoliv   # optional: filter account by name substring
#
# Environment:
#   THOUSANDEYES_API_TOKEN  Used if the first argument is omitted.
#   TE_ACCOUNT_SUBSTRING    Same as optional 2nd arg (case-insensitive match on accountGroupName).
#
# Requires: curl, jq

set -euo pipefail

BASE_URL="${THOUSANDEYES_API_BASE:-https://api.thousandeyes.com/v7}"

usage() {
  echo "Usage: $0 <API_TOKEN> [account_name_substring]" >&2
  echo "   or: THOUSANDEYES_API_TOKEN=... $0 [account_name_substring]" >&2
}

if ! command -v jq >/dev/null 2>&1; then
  echo "This script requires jq on PATH." >&2
  exit 1
fi

TOKEN="${1:-${THOUSANDEYES_API_TOKEN:-}}"
ACCOUNT_FILTER="${2:-${TE_ACCOUNT_SUBSTRING:-}}"

if [[ -z "${TOKEN}" ]]; then
  usage
  exit 1
fi

die() {
  echo "Error: $*" >&2
  exit 1
}

# GET: print body to stdout; on failure print body to stderr and exit 1.
http_get() {
  local url="$1"
  local tmp code
  tmp=$(mktemp)
  code=$(curl -sS -w "%{http_code}" -o "$tmp" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "$url") || die "curl failed for GET $url"
  if [[ "${code}" != 2* ]]; then
    echo "GET $url -> HTTP ${code}" >&2
    cat "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# POST: body from stdin or arg; print response body to stdout.
http_post_json() {
  local url="$1"
  local data="$2"
  local tmp code
  tmp=$(mktemp)
  code=$(curl -sS -w "%{http_code}" -o "$tmp" -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${data}" \
    "$url") || die "curl failed for POST $url"
  if [[ "${code}" != 2* ]]; then
    echo "POST $url -> HTTP ${code}" >&2
    cat "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# --- Step 1: account id (aid) ---
echo "Fetching account groups..." >&2
groups_json=$(http_get "${BASE_URL}/account-groups")

if [[ -n "${ACCOUNT_FILTER}" ]]; then
  aid=$(jq -r --arg f "${ACCOUNT_FILTER}" '
    [.accountGroups[]
      | select((.accountGroupName | ascii_downcase | index($f | ascii_downcase)) != null)
      | .aid]
    | if length == 1 then .[0]
      elif length == 0 then "error:no_match"
      else "error:ambiguous"
      end
  ' <<<"${groups_json}")
  if [[ "${aid}" == "error:no_match" ]]; then
    echo "No account group matched substring '${ACCOUNT_FILTER}'." >&2
    jq -r '.accountGroups[] | "\(.accountGroupName) (\(.aid))"' <<<"${groups_json}" >&2 || true
    exit 1
  fi
  if [[ "${aid}" == "error:ambiguous" ]]; then
    echo "Multiple account groups matched '${ACCOUNT_FILTER}'. Refine the substring." >&2
    jq -r --arg f "${ACCOUNT_FILTER}" '.accountGroups[] | select((.accountGroupName | ascii_downcase | index($f | ascii_downcase)) != null) | "\(.accountGroupName) (\(.aid))"' <<<"${groups_json}" >&2 || true
    exit 1
  fi
else
  aid=$(jq -r '
    [.accountGroups[] | select(.isCurrentAccountGroup == true) | .aid]
    | if length == 1 then .[0]
      elif length == 0 then "error:none_current"
      else "error:multiple_current"
      end
  ' <<<"${groups_json}")
  if [[ "${aid}" == "error:none_current" ]]; then
    die "No account group has isCurrentAccountGroup=true. Pass a name substring as arg 2 or set TE_ACCOUNT_SUBSTRING."
  fi
  if [[ "${aid}" == "error:multiple_current" ]]; then
    die "Multiple current account groups reported; pass a name substring as arg 2 or set TE_ACCOUNT_SUBSTRING."
  fi
fi

echo "Using account id (aid): ${aid}" >&2

# --- Step 2: page-load test ---
echo "Creating page-load test..." >&2
page_load_payload='{
  "testName": "online-boutique-us",
  "url": "https://online-boutique-us.splunko11y.com",
  "interval": 60,
  "agents": [
    { "agentId": "4495" }
  ],
  "pageLoadTimeLimit": 10,
  "pageLoadTargetTime": 8,
  "httpVersion": 2,
  "authType": "NONE",
  "alertsEnabled": true,
  "enabled": true
}'

test_resp=$(http_post_json "${BASE_URL}/tests/page-load?aid=${aid}" "${page_load_payload}")
test_id=$(jq -r '.testId // empty' <<<"${test_resp}")
if [[ -z "${test_id}" || "${test_id}" == "null" ]]; then
  echo "Could not read testId from response:" >&2
  echo "${test_resp}" >&2
  exit 1
fi
echo "Created testId: ${test_id}" >&2

# --- Step 3: alert rule ---
echo "Creating alert rule..." >&2
alert_payload=$(jq -n --arg tid "${test_id}" '{
  "ruleName": "page-load-alert-online-boutique",
  "description": "Alert if page load total time exceeds 800 ms",
  "alertType": "page-load",
  "alertGroupType": "cloud-enterprise",
  "severity": "major",
  "expression": "((onLoadTime >= 500 ms))",
  "minimumSources": 1,
  "roundsViolatingOutOf": 3,
  "roundsViolatingRequired": 3,
  "notifyOnClear": true,
  "testIds": [$tid]
}')

rule_resp=$(http_post_json "${BASE_URL}/alerts/rules?aid=${aid}" "${alert_payload}")
rule_id=$(jq -r '.ruleId // empty' <<<"${rule_resp}")
if [[ -z "${rule_id}" || "${rule_id}" == "null" ]]; then
  echo "Could not read ruleId from response:" >&2
  echo "${rule_resp}" >&2
  exit 1
fi
echo "Created ruleId: ${rule_id}" >&2

echo "---"
echo "accountId (aid): ${aid}"
echo "testId:         ${test_id}"
echo "ruleId:         ${rule_id}"
