#!/bin/bash
#
# Writes the issues of the analysis scan sent as a SARIF 2.1.0 file, for the
# export_sarif command. SonarQube has no SARIF export, so this reads the
# analysis from the Web API: it waits for the server's task that processes
# the analysis (api/ce/task), then reads the analyzed branch's or pull
# request's unresolved issues (api/issues/search) with their rules' names,
# and turns them into one SARIF run that GitHub code scanning, among others,
# can read. Each result is placed in the file the issue is in, relative to
# the repository's root. GitHub matches alerts from one upload to the next
# by primaryLocationLineHash, which it doesn't compute for an upload, so
# that is SonarQube's own hash of the issue's line with the rule, the same
# on a branch and its pull requests.
#
# The token needs Browse and Execute Analysis permission on the project,
# which a user token of the user that runs the analyses has: api/ce/task
# answers only to Execute Analysis or Administer. Project and global
# analysis tokens can't read issues.
#
# SonarQube returns at most 10,000 issues for one search; more than that
# fails the step unless max_issues_truncate is true. Security hotspots are
# not issues, and are left out.

set -euo pipefail

if [[ -z "${SCRIPT_SONARQUBE_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_SONARQUBE_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_SONARQUBE_LIB}"

HOST_URL=$(sq_subst "${PARAM_HOST_URL}")
REPORT_TASK=$(sq_subst "${PARAM_REPORT_TASK_FILE}")
if [[ -z "${REPORT_TASK}" ]]; then
    REPORT_TASK=${SONARQUBE_ORB_REPORT_TASK:-.scannerwork/report-task.txt}
fi
OUTPUT_DIR=${PARAM_OUTPUT_DIR}
REPORT_NAME=$(sq_subst "${PARAM_REPORT_NAME}")
CATEGORY=$(sq_subst "${PARAM_CATEGORY}")
WAIT_TIMEOUT=$(sq_subst "${PARAM_WAIT_TIMEOUT}")
TRUNCATE=$(sq_bool max_issues_truncate "${PARAM_MAX_ISSUES_TRUNCATE}")
sq_env_var_name sarif_file_env_var "${PARAM_SARIF_FILE_ENV_VAR}"
sq_token "${PARAM_TOKEN}"
if ! sq_match "${WAIT_TIMEOUT}" '^[1-9][0-9]{0,5}$'; then
    echo "ERROR: wait_timeout must be a number of seconds, not '${WAIT_TIMEOUT}'." >&2
    exit 1
fi
if [[ "${OUTPUT_DIR}" != /* ]]; then
    echo "ERROR: output_dir must be an absolute path, not '${OUTPUT_DIR}'." >&2
    exit 1
fi
if ! sq_match "${REPORT_NAME}" '^[A-Za-z0-9_][A-Za-z0-9_.-]*$'; then
    echo "ERROR: report_name must be a file name of letters, digits, '.', '_' and '-', not '${REPORT_NAME}'." >&2
    exit 1
fi
if ! sq_match "${CATEGORY}" '^[A-Za-z0-9_./:-]+$'; then
    echo "ERROR: category must be letters, digits and . _ / : -, not '${CATEGORY}'." >&2
    exit 1
fi
if ! command -v jq > /dev/null 2>&1; then
    echo "ERROR: export_sarif needs jq, which is not on the PATH. Install it in an earlier step." >&2
    exit 1
fi

# What scan sent. The report's lines are key=value, not escaped.
if [[ ! -f "${REPORT_TASK}" ]]; then
    echo "ERROR: There is no ${REPORT_TASK}, the file the scanner writes when it sends an analysis." >&2
    echo "  Run scan first, in the same job, or set report_task_file." >&2
    exit 1
fi
task_field() {
    awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "${REPORT_TASK}"
}
PROJECT_KEY=$(task_field projectKey)
SERVER=$(task_field serverUrl)
TASK_ID=$(task_field ceTaskId)
SERVER=${SERVER%/}
if [[ -z "${PROJECT_KEY}" || -z "${SERVER}" || -z "${TASK_ID}" ]]; then
    echo "ERROR: ${REPORT_TASK} does not name the project, server and task (projectKey, serverUrl, ceTaskId)." >&2
    exit 1
fi
if ! sq_match "${TASK_ID}" '^[A-Za-z0-9_-]+$'; then
    echo "ERROR: ${REPORT_TASK} names an invalid task, '${TASK_ID}'." >&2
    exit 1
fi
# The server: host_url, else SONAR_HOST_URL, else the report's serverUrl,
# which is the server's own idea of its URL and not always one this job can
# reach.
# shellcheck disable=SC2034 # read by sq_host_url
declare -A SQ_PROPS=([sonar.host.url]="${SERVER}")
sq_host_url "${HOST_URL}"
if [[ "${SQ_HOST_URL}" != https://* ]] && ! sq_loopback "${SQ_HOST_URL}"; then
    echo "ERROR: The server, ${SQ_HOST_URL}, is http://, and this orb only sends the token over https (or to localhost)." >&2
    exit 1
fi
if [[ -z "${SQ_TOKEN}" ]]; then
    echo "ERROR: ${SQ_TOKEN_VAR}, the environment variable the token parameter names, is empty." >&2
    echo "  Reading the analysis needs a user token with Browse and Execute Analysis permission on the project." >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
sq_curl_init
SQ_AUTH_FILE="${WORK}/auth"
sq_auth_header "${SQ_AUTH_FILE}" Authorization "Bearer ${SQ_TOKEN}"

# api GET_PATH OUT: calls the server's Web API, and stops the step unless it
# answers 200. A 503, which issue search answers while the server indexes
# issues, is tried again.
api() {
    local code attempt
    for attempt in 1 2 3 4 5 6; do
        code=$(sq_api "${SQ_HOST_URL}/$1" "$2") || code=""
        if [[ "${code}" != 503 ]]; then
            break
        fi
        sleep $((attempt * 5))
    done
    if [[ "${code}" != 200 ]]; then
        echo "ERROR: ${SQ_HOST_URL}/${1%%\?*} answered HTTP ${code:-nothing}: $(jq -r '[.errors[]?.msg] | join(" ")' "$2" 2> /dev/null || true)" >&2
        if [[ "${code}" == 401 || "${code}" == 403 ]]; then
            echo "  The token in ${SQ_TOKEN_VAR} needs Browse and Execute Analysis permission on ${PROJECT_KEY}:" >&2
            echo "  use a user token, since project and global analysis tokens can only send analyses." >&2
        fi
        exit 1
    fi
}

# The server processes the analysis after the scanner sends it.
echo "Waiting for ${SQ_HOST_URL} to process the analysis of ${PROJECT_KEY} (task ${TASK_ID})..."
DEADLINE=$((SECONDS + WAIT_TIMEOUT))
DELAY=2
while true; do
    api "api/ce/task?id=${TASK_ID}" "${WORK}/task.json"
    STATUS=$(jq -r '.task.status // empty' "${WORK}/task.json")
    case "${STATUS}" in
        SUCCESS) break ;;
        FAILED | CANCELED)
            echo "ERROR: The server's processing of the analysis ended ${STATUS}: $(jq -r '.task.errorMessage // "no reason given"' "${WORK}/task.json")" >&2
            exit 1
            ;;
        PENDING | IN_PROGRESS) ;;
        *)
            echo "ERROR: The server says task ${TASK_ID} is '${STATUS}', which this step doesn't know." >&2
            exit 1
            ;;
    esac
    if [[ "${SECONDS}" -ge "${DEADLINE}" ]]; then
        echo "ERROR: The server had not processed the analysis after ${WAIT_TIMEOUT} seconds (status ${STATUS}). Raise wait_timeout." >&2
        exit 1
    fi
    sleep "${DELAY}"
    if [[ "${DELAY}" -lt 10 ]]; then
        DELAY=$((DELAY * 2))
    fi
done
COMPONENT=$(jq -r '.task.componentKey // empty' "${WORK}/task.json")
COMPONENT=${COMPONENT:-${PROJECT_KEY}}
BRANCH=$(jq -r '.task.branch // empty' "${WORK}/task.json")
PULL_REQUEST=$(jq -r '.task.pullRequest // empty' "${WORK}/task.json")
# componentKeys, which SonarQube Server also takes as components, is the
# name SonarQube Cloud knows.
SELECT="componentKeys=$(jq -rn --arg v "${COMPONENT}" '$v | @uri')"
if [[ -n "${PULL_REQUEST}" ]]; then
    SELECT+="&pullRequest=$(jq -rn --arg v "${PULL_REQUEST}" '$v | @uri')"
    ANALYZED="pull request ${PULL_REQUEST}"
elif [[ -n "${BRANCH}" ]]; then
    SELECT+="&branch=$(jq -rn --arg v "${BRANCH}" '$v | @uri')"
    ANALYZED="branch ${BRANCH}"
else
    ANALYZED="the main branch"
fi

# Its unresolved issues, 500 a page, up to the 10,000 a search returns.
# SonarQube Cloud counts no further than 10,000, so that many may be more.
PAGE=1
: > "${WORK}/issues.jsonl"
: > "${WORK}/rules.jsonl"
while true; do
    api "api/issues/search?${SELECT}&resolved=false&additionalFields=rules&ps=500&p=${PAGE}" "${WORK}/page.json"
    jq -c '.issues[]?' "${WORK}/page.json" >> "${WORK}/issues.jsonl"
    jq -c '.rules[]?' "${WORK}/page.json" >> "${WORK}/rules.jsonl"
    TOTAL=$(jq -r '.paging.total // .total // 0' "${WORK}/page.json")
    if [[ "$((PAGE * 500))" -ge "${TOTAL}" || "$((PAGE * 500))" -ge 10000 ]]; then
        break
    fi
    PAGE=$((PAGE + 1))
done
COUNT=$(wc -l < "${WORK}/issues.jsonl")
if [[ "${TOTAL}" -ge 10000 ]]; then
    if [[ "${TRUNCATE}" == "true" ]]; then
        echo "WARN: ${PROJECT_KEY} has ${TOTAL} or more unresolved issues, and SonarQube returns 10,000 of them at most: the SARIF file has the first ${COUNT}." >&2
    else
        echo "ERROR: ${PROJECT_KEY} has ${TOTAL} or more unresolved issues, and SonarQube returns 10,000 of them at most." >&2
        echo "  Set max_issues_truncate to true to export the first 10,000." >&2
        exit 1
    fi
fi

# Paths in SonarQube are relative to the project's base directory, this
# one; SARIF's are relative to the repository's root.
PREFIX=""
if command -v git > /dev/null 2>&1 && git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    PREFIX=$(git rev-parse --show-prefix)
fi

mkdir -p "${OUTPUT_DIR}"
SARIF="${OUTPUT_DIR}/${REPORT_NAME}.sarif"
jq -n --slurpfile issues "${WORK}/issues.jsonl" --slurpfile rules "${WORK}/rules.jsonl" \
    --arg project "${COMPONENT}" --arg server "${SQ_HOST_URL}" --arg prefix "${PREFIX}" \
    --arg category "${CATEGORY}/${COMPONENT}/" --arg version "$(jq -r '.task.serverVersion // empty' "${WORK}/task.json")" '
    # A SonarQube severity, from an issue impact or the legacy severity, as a
    # SARIF level.
    def level($s):
        if $s == "BLOCKER" or $s == "CRITICAL" or $s == "HIGH" then "error"
        elif $s == "MAJOR" or $s == "MEDIUM" then "warning"
        else "note" end;
    def rank($l): {"error": 3, "warning": 2, "note": 1}[$l] // 0;
    # GitHub orders security alerts by security-severity, a CVSS-like score
    # written as a string.
    def score($s):
        if $s == "BLOCKER" then "9.5"
        elif $s == "CRITICAL" or $s == "HIGH" then "8.0"
        elif $s == "MAJOR" or $s == "MEDIUM" then "5.5"
        else "2.0" end;
    def severities: if ((.impacts // []) | length) > 0 then [.impacts[].severity] else [.severity // "INFO"] end;
    def issue_level: [severities[] | level(.)] | max_by(rank(.));
    def security: (.type == "VULNERABILITY") or any((.impacts // [])[]; .softwareQuality == "SECURITY");
    def path: .component | ltrimstr($project + ":");
    ($rules | map({key: .key, value: .}) | from_entries) as $names
    | [$issues[] | select(.component != $project and (.component | startswith($project + ":")))]
    # The issue ahead of it with the same rule, file and line hash, numbered,
    # so two such issues get fingerprints of their own.
    | [group_by([.rule, .component, (.hash // .key)])[] | to_entries[] | .value + {occurrence: (.key + 1)}] as $placed
    | ($placed | group_by(.rule)) as $by_rule
    | {
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        version: "2.1.0",
        runs: [{
            tool: {driver: ({
                name: "SonarQube",
                informationUri: "https://www.sonarsource.com/products/sonarqube/",
                rules: [$by_rule[] | .[0].rule as $id | ({
                    id: $id,
                    name: $id,
                    shortDescription: {text: ($names[$id].name // $id)},
                    helpUri: ($server + "/coding_rules?open=" + ($id | @uri) + "&rule_key=" + ($id | @uri)),
                    properties: ({tags: ([.[] | .tags // [] | .[]] | unique)}
                        + (if any(.[]; security) then
                            {"security-severity": ([.[] | severities[] | score(.)] | max_by(tonumber))}
                        else {} end))
                })]
            } + (if $version != "" then {version: $version} else {} end))},
            automationDetails: {id: $category},
            results: [$placed[] | {
                ruleId: .rule,
                level: issue_level,
                message: {text: .message},
                locations: [{physicalLocation: ({
                    artifactLocation: {uri: ($prefix + path)}
                } + (if .textRange then {region: {
                    startLine: .textRange.startLine,
                    endLine: .textRange.endLine,
                    startColumn: (.textRange.startOffset + 1),
                    endColumn: (.textRange.endOffset + 1)
                }} else {region: {startLine: (.line // 1)}} end))}],
                partialFingerprints: {
                    primaryLocationLineHash: ("\(.rule):\(.hash // .key):\(.occurrence)"),
                    "sonarqubeIssueKey/v1": .key
                },
                properties: ({sonarqubeIssueKey: .key, sonarqubeUrl: ($server + "/project/issues?id=" + ($project | @uri) + "&open=" + (.key | @uri))}
                    + (if .severity then {severity: .severity} else {} end)
                    + (if .type then {type: .type} else {} end)
                    + (if .impacts then {impacts: .impacts} else {} end))
            }]
        }]
    }' > "${SARIF}.tmp"
mv -f "${SARIF}.tmp" "${SARIF}"
RESULTS=$(jq '.runs[0].results | length' "${SARIF}")
SKIPPED=$((COUNT - RESULTS))
echo "Wrote ${SARIF}: ${RESULTS} unresolved issues of ${ANALYZED}${SKIPPED:+$([[ "${SKIPPED}" -gt 0 ]] && echo ", leaving out ${SKIPPED} that are not in a file")}."
sq_export "${PARAM_SARIF_FILE_ENV_VAR}" "${SARIF}"
