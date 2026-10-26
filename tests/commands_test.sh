#!/usr/bin/env bash
#
# Tests the command scripts offline, against stand-ins: a sonar-scanner that
# records how it was run and answers with the scenario each test picks
# (an analysis sent, a failed quality gate, Community Build refusing a
# branch, a failure), the CircleCI CLI's env subst, and tests/fake_server.py
# on 127.0.0.1 for the SonarQube Web API and GitHub's REST API, which the
# scripts reach with the real curl.
#
# What the real scanner and servers do is checked by test-deploy.yml and the
# GitHub Actions workflow, which run every command against SonarQube
# Community Build.
#
# Needs curl, git, jq, gzip, base64 and python3. Run from a checkout:
#   bash tests/commands_test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS="${ROOT}/src/scripts"
WORK=$(mktemp -d)
STUBS="${WORK}/stubs"
CALLS="${WORK}/calls"
mkdir -p "${STUBS}" "${CALLS}"
for tool in curl git jq gzip base64 python3; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
        echo "ERROR: These tests need ${tool}." >&2
        exit 1
    fi
done
export CALLS

FAILURES=0
OUTPUT=""
RC=0
CASE=""

begin() {
    echo "--- $1"
}
check() {
    local name=$1
    shift
    if "$@"; then
        echo "  ok: ${name}"
    else
        echo "  FAIL: ${name}"
        tail -n 25 <<< "${OUTPUT}" | while IFS= read -r line; do printf '    | %s\n' "${line}"; done
        FAILURES=$((FAILURES + 1))
    fi
}
succeeded() { [[ "${RC}" -eq 0 ]]; }
failed() { [[ "${RC}" -ne 0 ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
not_said() { ! said "$1"; }
file_has() { grep -qF -- "$2" "$1"; }
not_file_has() { ! grep -qF -- "$2" "$1" 2> /dev/null; }
json_is() { [[ "$(jq -r "$2" "$1" 2> /dev/null)" == "$3" ]] || { OUTPUT+=$'\n'"$1: $2 is $(jq -c "$2" "$1" 2>&1)"; return 1; }; }
exists() { [[ -e "$1" ]]; }
absent() { [[ ! -e "$1" ]]; }
# scanner_arg WORD: the last scanner call had WORD among its arguments.
scanner_arg() {
    grep -qxF -- "$1" "${CALLS}/sonar-scanner.args" 2> /dev/null || {
        OUTPUT+=$'\n'"scanner arguments: $(tr '\n' ' ' < "${CALLS}/sonar-scanner.args" 2> /dev/null)"
        return 1
    }
}
no_scanner_arg() {
    local saved=${OUTPUT}
    if scanner_arg "$1"; then
        return 1
    fi
    OUTPUT=${saved}
}
# exported NAME VALUE: the case's BASH_ENV exports NAME as VALUE.
exported() {
    local got
    got=$(bash -c 'source "$1" && printf "%s" "${!2-<unset>}"' _ "${CASE}/bash_env" "$1" 2>&1)
    [[ "${got}" == "$2" ]] || { OUTPUT+=$'\n'"$1 is exported as '${got}', not '$2'"; return 1; }
}
not_exported() { ! grep -q "^export $1=" "${CASE}/bash_env"; }
# requested FILTER: some request the fake server logged matches the jq FILTER.
requested() {
    jq -e -s "any(.[]; $1)" "${WORK}/server.log" > /dev/null 2>&1 || {
        OUTPUT+=$'\n'"requests: $(jq -c '{method, path, query}' "${WORK}/server.log" 2>&1 | tr '\n' ' ')"
        return 1
    }
}
no_requests() { [[ ! -s "${WORK}/server.log" ]]; }
not_requested() { ! jq -e -s "any(.[]; $1)" "${WORK}/server.log" > /dev/null 2>&1; }

# Stand-ins.
cat > "${STUBS}/circleci" << 'EOF'
#!/usr/bin/env bash
# Like `circleci env subst`: expands $NAME and ${NAME} on stdin.
input=$(cat)
output=""
re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
while [[ "${input}" =~ ${re} ]]; do
    name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    output+="${BASH_REMATCH[1]}${!name-}"
    input=${BASH_REMATCH[5]}
done
printf '%s\n' "${output}${input}"
EOF
# sonar-scanner, in a tree like the real one's (bin/, jre/bin/java), records
# its arguments and environment, and answers as STUB_SCAN says: ok (the
# default), gate (a failed quality gate), timeout (the gate's timeout),
# community (Community Build refusing a branch), noreport (succeeds without
# writing the report) or error.
mkdir -p "${WORK}/scanner/bin" "${WORK}/scanner/jre/bin"
printf '#!/bin/sh\nexit 0\n' > "${WORK}/scanner/jre/bin/java"
cat > "${WORK}/scanner/bin/sonar-scanner" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
    echo "INFO SonarScanner CLI 8.2.0.6438"
    exit 0
fi
printf '%s\n' "$@" > "${CALLS}/sonar-scanner.args"
{
    printf 'SONAR_TOKEN=%s\n' "${SONAR_TOKEN-<unset>}"
    printf 'SONAR_SCANNER_OPTS=%s\n' "${SONAR_SCANNER_OPTS-<unset>}"
    printf 'SONAR_SCANNER_JAVA_OPTS=%s\n' "${SONAR_SCANNER_JAVA_OPTS-<unset>}"
} > "${CALLS}/sonar-scanner.env"
metadata="" key=""
for arg in "$@"; do
    case "${arg}" in
        -Dsonar.scanner.metadataFilePath=*) metadata=${arg#*=} ;;
        -Dsonar.projectKey=*) key=${arg#*=} ;;
    esac
done
key=${key:-$(sed -n 's/^sonar.projectKey=//p' sonar-project.properties 2> /dev/null)}
report() {
    printf 'projectKey=%s\nserverUrl=%s\nserverVersion=26.10.0.133078\ndashboardUrl=%s/dashboard?id=%s\nceTaskId=AZtask1\nceTaskUrl=%s/api/ce/task?id=AZtask1\n' \
        "${key}" "${STUB_SERVER:-http://127.0.0.1:9}" "${STUB_SERVER:-http://127.0.0.1:9}" "${key}" "${STUB_SERVER:-http://127.0.0.1:9}" > "${metadata}"
}
echo "INFO Analysis of ${key}"
case "${STUB_SCAN:-ok}" in
    ok) report; echo "INFO EXECUTION SUCCESS"; exit 0 ;;
    gate) report; echo "INFO QUALITY GATE STATUS: FAILED - View details on http://sonar/dashboard"; echo "ERROR EXECUTION FAILURE"; exit 3 ;;
    timeout) report; echo "ERROR Quality Gate check timeout exceeded - View details on http://sonar/dashboard"; exit 3 ;;
    community)
        echo 'ERROR Validation of project failed:'
        echo '  o To use the property "sonar.branch.name" and analyze branches, Developer Edition or above is required.'
        exit 3 ;;
    noreport) exit 0 ;;
    error) echo "ERROR Error during SonarScanner Engine execution"; exit 1 ;;
esac
EOF
chmod +x "${STUBS}"/* "${WORK}/scanner/bin/sonar-scanner" "${WORK}/scanner/jre/bin/java"
ln -s "${WORK}/scanner/bin/sonar-scanner" "${STUBS}/sonar-scanner"

# The fake server, for the rest of the run.
: > "${WORK}/routes.json"
echo '[]' > "${WORK}/routes.json"
python3 "${ROOT}/tests/fake_server.py" "${WORK}/routes.json" "${WORK}/server.log" "${WORK}/port" &
SERVER_PID=$!
# So bash doesn't report the server as terminated when the trap stops it.
disown "${SERVER_PID}"
trap 'kill "${SERVER_PID}" 2> /dev/null; rm -rf "${WORK}"' EXIT
for _ in $(seq 1 100); do
    [[ -s "${WORK}/port" ]] && break
    sleep 0.1
done
if [[ ! -s "${WORK}/port" ]]; then
    echo "ERROR: The fake server did not start." >&2
    exit 1
fi
SERVER="http://127.0.0.1:$(cat "${WORK}/port")"
# routes JSON: the fake server's routes from now on, with its turns and log
# started over.
routes() {
    printf '%s\n' "$1" > "${WORK}/routes.json"
    curl -sS -o /dev/null "${SERVER}/__reset"
}

# new_case: a fresh project in CASE/repo/app, a git repository with
# sonar-project.properties and a source directory, and a BASH_ENV of its
# own.
new_case() {
    CASE=$(mktemp -d "${WORK}/case.XXXXXX")
    mkdir -p "${CASE}/repo/app/src" "${CASE}/repo/app/test"
    printf 'sonar.projectKey=demo\nsonar.sources=src\nsonar.tests=test\n' > "${CASE}/repo/app/sonar-project.properties"
    printf 'print("hi")\n' > "${CASE}/repo/app/src/main.py"
    git -C "${CASE}/repo" init -q -b main 2> /dev/null || git -C "${CASE}/repo" init -q
    git -C "${CASE}/repo" add -A
    git -C "${CASE}/repo" -c user.name=t -c user.email=t@example.com commit -qm init
    : > "${CASE}/bash_env"
    rm -f "${CALLS}"/*
    routes '[]'
}

# run COMMAND [NAME=VALUE...]: runs the command's script in CASE/repo/app
# (DIR=path relative to CASE/repo changes that) with the command's parameter
# defaults, overridden by NAME=VALUE, as tests/run_command.sh does. A
# lowercase name is a parameter; anything else is set as it is. The CI
# environment of the job running the tests is removed.
DEFAULTS_CACHE="${WORK}/defaults"
mkdir -p "${DEFAULTS_CACHE}"
run() {
    local command=$1 settings=() dir="app"
    local -a defaults=()
    shift
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == DIR=* ]]; then
            dir=${1#DIR=}
        elif [[ "${1%%=*}" =~ ^[a-z][a-z0-9_]*$ ]]; then
            settings+=("PARAM_$(tr '[:lower:]' '[:upper:]' <<< "${1%%=*}")=${1#*=}")
        else
            settings+=("$1")
        fi
        shift
    done
    if [[ ! -f "${DEFAULTS_CACHE}/${command}" ]]; then
        awk '
            function flush() { if (name != "") printf "PARAM_%s=%s\n", toupper(name), value }
            /^parameters:/ { p = 1; next }
            /^[^ ]/ { if (p) flush(); p = 0; name = "" }
            p && /^  [a-z_0-9]+:$/ { flush(); name = $1; sub(/:$/, "", name); value = "" }
            p && /^    default:/ { value = $0; sub(/^    default: */, "", value); if (value ~ /^".*"$/) value = substr(value, 2, length(value) - 2) }
            END { if (p) flush() }' "${ROOT}/src/commands/${command}.yml" | grep -v '^PARAM_WORKING_DIR=' > "${DEFAULTS_CACHE}/${command}"
    fi
    mapfile -t defaults < "${DEFAULTS_CACHE}/${command}"
    defaults+=("PARAM_OUTPUT_DIR=${CASE}/out")
    OUTPUT=$(cd "${CASE}/repo/${dir}" && env -i HOME="${CASE}" PATH="${STUBS}:${PATH}" BASH_ENV="${CASE}/bash_env" \
        TMPDIR="${WORK}" CALLS="${CALLS}" STUB_SERVER="${SERVER}" \
        SCRIPT_SONARQUBE_LIB="$(cat "${SCRIPTS}/lib/sonarqube.sh")" \
        "${defaults[@]}" ${settings[@]+"${settings[@]}"} bash "${SCRIPTS}/${command}.sh" 2>&1)
    RC=$?
}

SETUP_ROUTES_COMMUNITY='[{"path": "/api/navigation/global", "responses": [{"json": {"edition": "community", "version": "26.10.0.133078"}}]}]'

echo "=== setup"
begin "the properties file"
new_case
run setup
check "succeeds with a valid file" succeeded
check "names the project" said "SonarQube analysis of demo in"
check "prints what the file sets" said "  sonar.sources=src"
check "exports no properties without CI" exported SONARQUBE_ORB_PROPERTIES ""
new_case
rm "${CASE}/repo/app/sonar-project.properties"
run setup
check "fails without sonar-project.properties" failed
check "saying where it looked" said "There is no sonar-project.properties in ${CASE}/repo/app."
check "exports nothing" not_exported SONARQUBE_ORB_PROPERTIES
run setup require_properties_file=false
check "without it, require_properties_file false still needs project_key" said "set project_key"
run setup require_properties_file=false project_key=demo-key
check "and with project_key succeeds" succeeded
check "passing the key on" exported SONARQUBE_ORB_PROPERTIES "sonar.projectKey=demo-key"
new_case
printf 'sonar.sources=src\n' > "${CASE}/repo/app/sonar-project.properties"
run setup
check "a file without sonar.projectKey fails" failed
check "saying so" said "has no sonar.projectKey"
for key in "12345" "has space" "a/b"; do
    new_case
    run setup "project_key=${key}"
    check "refuses the project key '${key}'" failed
    check "saying what SonarQube accepts" said "is not one SonarQube accepts"
done
new_case
run setup project_key=org:app_1.x-2
check "accepts letters, digits and - _ . :" succeeded
new_case
mv "${CASE}/repo/app/sonar-project.properties" "${CASE}/repo/app/ci.properties"
run setup properties_file=ci.properties
check "another properties file is read" said "SonarQube analysis of demo"
check "and passed on as project.settings" exported SONARQUBE_ORB_PROPERTIES "project.settings=ci.properties"

begin "the properties file's format"
new_case
cat > "${CASE}/repo/app/sonar-project.properties" << 'EOF'
# a comment
! another comment
sonar.projectKey : demo
sonar.projectName   My Project
sonar.sources=src,\
    test
sonar.exclusions=**/gen/**
key\=with\:escapes=value
sonar.projectKey=demo2
EOF
run setup
check "reads key: value and key value" said "  sonar.projectName=My Project"
check "joins continued lines" said "  sonar.sources=src,test"
check "unescapes keys" said "  key=with:escapes=value"
check "lets a later definition win" said "SonarQube analysis of demo2"
check "skips comments" not_said "comment"

begin "credentials and paths"
new_case
printf 'sonar.projectKey=demo\nsonar.sources=src\nsonar.login=squ_s3cr3t\nsonar.token=squ_t0k3n\n' > "${CASE}/repo/app/sonar-project.properties"
run setup
check "warns about a credential in the file" said "sets sonar.login, a credential, in the repository"
check "and each one" said "sets sonar.token, a credential"
check "never prints them" not_said "squ_s3cr3t"
check "nor the other" not_said "squ_t0k3n"
check "hiding their values" said "  sonar.login=********"
new_case
printf 'sonar.projectKey=demo\nsonar.sources=src,missing\nsonar.tests=test\n' > "${CASE}/repo/app/sonar-project.properties"
run setup
check "fails when sonar.sources names a path that doesn't exist" failed
check "saying which" said "sonar.sources in sonar-project.properties names missing, which does not exist"
new_case
mkdir -p "${CASE}/repo/app/sub/src"
printf 'sonar.projectKey=demo\nsonar.projectBaseDir=sub\nsonar.sources=src\n' > "${CASE}/repo/app/sonar-project.properties"
rm -rf "${CASE}/repo/app/src"
run setup
check "paths are relative to sonar.projectBaseDir" succeeded

begin "CircleCI"
CIRCLE_PR=(CIRCLECI=true CIRCLE_BRANCH=feature/login CIRCLE_PULL_REQUEST=https://github.com/acme/app/pull/42 CIRCLE_SHA1=0123456789abcdef0123456789abcdef01234567)
new_case
run setup branch_analysis=true "${CIRCLE_PR[@]}"
check "a branch with a pull request analyzes the pull request" \
    exported SONARQUBE_ORB_PROPERTIES $'sonar.pullrequest.key=42\nsonar.pullrequest.branch=feature/login'
check "into the main branch, which CircleCI doesn't name" said "pull request 42 (feature/login into the main branch)"
run setup branch_analysis=true "${CIRCLE_PR[@]}" pull_request_base=develop
check "unless pull_request_base names it" \
    exported SONARQUBE_ORB_PROPERTIES $'sonar.pullrequest.key=42\nsonar.pullrequest.branch=feature/login\nsonar.pullrequest.base=develop'
new_case
run setup branch_analysis=true CIRCLECI=true CIRCLE_BRANCH=feature/x CIRCLE_PR_NUMBER=7 CIRCLE_PULL_REQUEST=https://github.com/fork/app/pull/7
check "a pull request from a fork uses CIRCLE_PR_NUMBER" exported SONARQUBE_ORB_PROPERTIES $'sonar.pullrequest.key=7\nsonar.pullrequest.branch=feature/x'
new_case
run setup branch_analysis=true CIRCLECI=true CIRCLE_BRANCH=release/1.x
check "a branch without a pull request analyzes the branch" exported SONARQUBE_ORB_PROPERTIES "sonar.branch.name=release/1.x"
new_case
run setup branch_analysis=true CIRCLECI=true CIRCLE_TAG=v1.0.0
check "a tag has no branch to name, so branch_analysis true fails" failed
check "saying what to set" said "branch_analysis is true, but this build has no branch or pull request"
run setup branch_analysis=auto CIRCLECI=true CIRCLE_TAG=v1.0.0
check "with auto, a tag analyzes the main branch" succeeded
check "warning about it" said "This build is for tag v1.0.0, with no branch"
new_case
run setup branch_analysis=true "${CIRCLE_PR[@]}" branch_name=main
check "branch_name makes it a branch analysis" exported SONARQUBE_ORB_PROPERTIES "sonar.branch.name=main"
run setup branch_analysis=true CIRCLECI=true CIRCLE_BRANCH=x pull_request_key=9 pull_request_branch=topic
check "pull_request_key and pull_request_branch make it a pull request" \
    exported SONARQUBE_ORB_PROPERTIES $'sonar.pullrequest.key=9\nsonar.pullrequest.branch=topic'
run setup branch_analysis=true pull_request_key=9
check "a pull request key without its branch fails" failed
check "asking for pull_request_branch" said "Set pull_request_branch."
run setup branch_analysis=true pull_request_key='9;rm' pull_request_branch=topic
check "a pull request key that isn't a number fails" failed

begin "GitHub Actions"
event="${WORK}/event.json"
printf '{"pull_request": {"number": 15}}\n' > "${event}"
GHA_PR=(GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/15/merge GITHUB_HEAD_REF=fix/typo GITHUB_BASE_REF=main
    "GITHUB_EVENT_PATH=${event}" GITHUB_SHA=89abcdef0123456789abcdef0123456789abcdef GITHUB_REPOSITORY=acme/app)
new_case
run setup branch_analysis=true "${GHA_PR[@]}"
check "a pull_request event analyzes the pull request into its base" \
    exported SONARQUBE_ORB_PROPERTIES $'sonar.pullrequest.key=15\nsonar.pullrequest.branch=fix/typo\nsonar.pullrequest.base=main'
check "the base is in the checkout, so there's no warning about it" not_said "The checkout has no main"
run setup branch_analysis=true "${GHA_PR[@]}" GITHUB_BASE_REF=develop
check "a base the checkout lacks is reported" said "The checkout has no develop, the branch pull request 15 goes into"
run setup branch_analysis=true "${GHA_PR[@]}" GITHUB_REF=refs/heads/x
check "the number also comes from the event file" exported SONARQUBE_ORB_PROPERTIES $'sonar.pullrequest.key=15\nsonar.pullrequest.branch=fix/typo\nsonar.pullrequest.base=main'
new_case
run setup branch_analysis=true GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/feature/a GITHUB_REF_NAME=feature/a GITHUB_REF_TYPE=branch
check "a push analyzes its branch" exported SONARQUBE_ORB_PROPERTIES "sonar.branch.name=feature/a"
new_case
run setup GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v2 GITHUB_REF_NAME=v2 GITHUB_REF_TYPE=tag
check "a tag push analyzes the main branch" exported SONARQUBE_ORB_PROPERTIES ""

begin "branch_analysis auto"
new_case
routes "${SETUP_ROUTES_COMMUNITY}"
run setup "host_url=${SERVER}" SONAR_TOKEN=squ_abc "${CIRCLE_PR[@]}"
check "asks the server which edition it is" requested '.path == "/api/navigation/global"'
check "with the token as a bearer token" requested '.authorization == "Bearer squ_abc"'
check "leaves branch properties out for Community Build" exported SONARQUBE_ORB_PROPERTIES ""
check "saying why" said "the server is Community Build, which analyzes the main branch only"
check "and that the pull request replaces the main branch's analysis" said "replaces the main branch's"
check "never printing the token" not_said "squ_abc"
new_case
routes '[{"path": "/api/navigation/global", "responses": [{"json": {"edition": "enterprise"}}]}]'
run setup "host_url=${SERVER}" SONAR_TOKEN=squ_abc "${CIRCLE_PR[@]}"
check "sends them for Enterprise Edition" exported SONARQUBE_ORB_PROPERTIES $'sonar.pullrequest.key=42\nsonar.pullrequest.branch=feature/login'
check "saying why" said "since the server is enterprise edition"
new_case
routes '[{"path": "/api/navigation/global", "responses": [{"status": 401, "json": {"errors": [{"msg": "Authentication is required"}]}}]},
    {"path": "/api/server/version", "responses": [{"text": "26.10.0.133078"}]}]'
run setup "host_url=${SERVER}" "${CIRCLE_PR[@]}"
check "without a token, tells Community Build by its version" exported SONARQUBE_ORB_PROPERTIES ""
check "asking for it" requested '.path == "/api/server/version"'
new_case
routes '[{"path": "/api/navigation/global", "responses": [{"status": 401, "json": {}}]}, {"path": "/api/server/version", "responses": [{"text": "2026.1.0.118200"}]}]'
run setup "host_url=${SERVER}" "${CIRCLE_PR[@]}"
check "a SonarQube Server version gets them" exported SONARQUBE_ORB_PROPERTIES $'sonar.pullrequest.key=42\nsonar.pullrequest.branch=feature/login'
check "with a warning that the edition is unknown" said "Could not tell which edition"
new_case
run setup host_url=https://sonarcloud.io "${CIRCLE_PR[@]}"
check "SonarQube Cloud gets them without asking" exported SONARQUBE_ORB_PROPERTIES $'sonar.pullrequest.key=42\nsonar.pullrequest.branch=feature/login'
check "the server isn't asked" no_requests
check "and it is reminded of sonar.organization" said "SonarQube Cloud needs the organization's key"
new_case
run setup host_url=http://sonar.internal.example "${CIRCLE_PR[@]}" SONAR_TOKEN=squ_abc
check "an http:// server isn't sent the token" said "this orb only sends the token over https"
new_case
run setup "host_url=${SERVER}" branch_analysis=false "${CIRCLE_PR[@]}"
check "branch_analysis false sends none" exported SONARQUBE_ORB_PROPERTIES ""
check "without asking" no_requests
new_case
run setup SONAR_HOST_URL=https://sonarqube.us "${CIRCLE_PR[@]}"
check "SONAR_HOST_URL is the server when host_url is empty" said "server:          https://sonarqube.us (from SONAR_HOST_URL)"
new_case
run setup host_url=https://user:pw@sonar.example.com
check "a server URL with credentials is refused" failed
check "without printing them" not_said "user:pw"

begin "properties the file shouldn't set"
new_case
printf 'sonar.projectKey=demo\nsonar.branch.name=master\n' > "${CASE}/repo/app/sonar-project.properties"
run setup branch_analysis=true CIRCLECI=true CIRCLE_BRANCH=main
check "a branch the file sets is reported" said "sets sonar.branch.name, which this setup replaces for the scan"

begin "the checkout"
new_case
git clone -q --depth 1 "file://${CASE}/repo" "${CASE}/repo/shallow" 2> /dev/null
run setup DIR=shallow/app
check "a shallow checkout is reported" said "This checkout is shallow"

echo "=== scan"
begin "the scanner's arguments"
new_case
run scan SONAR_TOKEN=squ_abc
check "succeeds" succeeded
check "writes the report to .scannerwork" scanner_arg "-Dsonar.scanner.metadataFilePath=${CASE}/repo/app/.scannerwork/report-task.txt"
check "passes no host when host_url is empty" no_scanner_arg "-Dsonar.host.url=${SERVER}"
check "the token reaches the scanner in its environment" file_has "${CALLS}/sonar-scanner.env" "SONAR_TOKEN=squ_abc"
check "not on its command line" not_file_has "${CALLS}/sonar-scanner.args" "squ_abc"
check "nor in the log" not_said "squ_abc"
check "Java options are left alone" file_has "${CALLS}/sonar-scanner.env" "SONAR_SCANNER_JAVA_OPTS=<unset>"
check "exports the dashboard URL" exported SONAR_DASHBOARD_URL "${SERVER}/dashboard?id=demo"
check "the task ID" exported SONAR_CE_TASK_ID AZtask1
check "and the report's path" exported SONARQUBE_ORB_REPORT_TASK "${CASE}/repo/app/.scannerwork/report-task.txt"
new_case
printf 'export SONARQUBE_ORB_PROPERTIES=%q\n' $'sonar.pullrequest.key=42\nsonar.pullrequest.branch=feature/login' > "${CASE}/setup_env"
run scan SONAR_TOKEN=squ_abc "host_url=${SERVER}/" verbose=true quality_gate_wait=true quality_gate_timeout=120 \
    properties=$'sonar.exclusions=**/gen/**\n# a comment\n\n  sonar.python.version=3.12  ' \
    "extra_args=-Dsonar.log.level=DEBUG '-Dsonar.projectName=My App'" java_opts=-Xmx2g \
    SONARQUBE_ORB_PROPERTIES=$'sonar.pullrequest.key=42\nsonar.pullrequest.branch=feature/login'
check "verbose is -X" scanner_arg "-X"
check "host_url is sonar.host.url, without the trailing slash" scanner_arg "-Dsonar.host.url=${SERVER}"
check "setup's properties are passed on" scanner_arg "-Dsonar.pullrequest.key=42"
check "each of them" scanner_arg "-Dsonar.pullrequest.branch=feature/login"
check "properties are passed on, trimmed" scanner_arg "-Dsonar.python.version=3.12"
check "skipping comments" no_scanner_arg "-D# a comment"
check "quality_gate_wait waits" scanner_arg "-Dsonar.qualitygate.wait=true"
check "for quality_gate_timeout" scanner_arg "-Dsonar.qualitygate.timeout=120"
check "extra_args are split like shell words" scanner_arg "-Dsonar.projectName=My App"
check "and come last" test "$(tail -n 1 "${CALLS}/sonar-scanner.args")" = "-Dsonar.projectName=My App"
check "java_opts reach the launcher" file_has "${CALLS}/sonar-scanner.env" "SONAR_SCANNER_OPTS=-Xmx2g"
check "and the analysis' Java runtime" file_has "${CALLS}/sonar-scanner.env" "SONAR_SCANNER_JAVA_OPTS=-Xmx2g"
new_case
run scan SONAR_TOKEN=squ_abc skip_jre_provisioning=true
check "skip_jre_provisioning skips the download" scanner_arg "-Dsonar.scanner.skipJreProvisioning=true"
check "and uses the scanner's own Java runtime" scanner_arg "-Dsonar.scanner.javaExePath=${WORK}/scanner/jre/bin/java"

begin "what the scan refuses"
new_case
run scan
check "an empty token fails" failed
check "saying which variable" said "SONAR_TOKEN, the environment variable the token parameter names, is empty."
check "before running the scanner" absent "${CALLS}/sonar-scanner.args"
run scan token=MY_TOKEN MY_TOKEN=squ_abc
check "token names the variable" succeeded
for props in "sonar.token=squ_x" "sonar.login=squ_x" "sonar.password=pw"; do
    run scan SONAR_TOKEN=squ_abc "properties=${props}"
    check "refuses ${props%%=*} in properties" failed
    check "without printing it" not_said "squ_x"
done
run scan SONAR_TOKEN=squ_abc "extra_args=-Dsonar.token=squ_x"
check "refuses sonar.token in extra_args" failed
run scan SONAR_TOKEN=squ_abc "extra_args=--define=sonar.login=squ_x"
check "in either form" failed
run scan SONAR_TOKEN=squ_abc "properties=sonar.scanner.metadataFilePath=/tmp/x"
check "refuses sonar.scanner.metadataFilePath" failed
run scan SONAR_TOKEN=squ_abc "properties=not a property"
check "refuses a line that isn't key=value" failed
# shellcheck disable=SC2016 # a command substitution scan must refuse
run scan SONAR_TOKEN=squ_abc 'extra_args=$(touch /tmp/pwned)'
check "refuses a command substitution in extra_args" failed
run scan SONAR_TOKEN=squ_abc quality_gate_timeout=soon
check "refuses a quality_gate_timeout that isn't a number" failed
run scan SONAR_TOKEN=squ_abc PATH="/usr/bin:/bin"
check "fails without sonar-scanner" failed
check "saying to install it" said "Run the install command in an earlier step."

begin "how the scan ends"
new_case
run scan SONAR_TOKEN=squ_abc STUB_SCAN=gate
check "a failed quality gate fails" failed
check "saying so" said "ERROR: The analysis failed its quality gate"
check "still exporting the dashboard URL" exported SONAR_DASHBOARD_URL "${SERVER}/dashboard?id=demo"
check "and the report" exported SONARQUBE_ORB_REPORT_TASK "${CASE}/repo/app/.scannerwork/report-task.txt"
new_case
run scan SONAR_TOKEN=squ_abc STUB_SCAN=timeout
check "the gate's timeout fails" failed
check "naming quality_gate_timeout" said "within quality_gate_timeout"
new_case
run scan SONAR_TOKEN=squ_abc STUB_SCAN=community
check "Community Build refusing a branch fails" failed
check "pointing at branch_analysis" said "Set setup's branch_analysis to auto or false"
new_case
mkdir -p "${CASE}/repo/app/.scannerwork"
printf 'ceTaskId=OLD\ndashboardUrl=old\n' > "${CASE}/repo/app/.scannerwork/report-task.txt"
run scan SONAR_TOKEN=squ_abc STUB_SCAN=noreport
check "a scanner that writes no report fails" failed
check "an earlier report is not taken for this one" not_exported SONAR_CE_TASK_ID
new_case
run scan SONAR_TOKEN=squ_abc STUB_SCAN=error
check "a scanner that fails fails" failed
check "with an ERROR line" said "ERROR: The SonarScanner CLI failed (exit code 1)"

echo "=== export_sarif"
# report_task KEY: writes CASE/repo/app/.scannerwork/report-task.txt for
# project KEY on the fake server.
report_task() {
    mkdir -p "${CASE}/repo/app/.scannerwork"
    printf 'projectKey=%s\nserverUrl=%s\nserverVersion=26.10\ndashboardUrl=%s/dashboard?id=%s\nceTaskId=AZtask1\nceTaskUrl=x\n' \
        "$1" "${SERVER}" "${SERVER}" "$1" > "${CASE}/repo/app/.scannerwork/report-task.txt"
}
ISSUES='{"paging": {"pageIndex": 1, "pageSize": 500, "total": 4}, "issues": [
  {"key": "I1", "rule": "python:S1481", "component": "demo:src/main.py", "message": "Remove unused local variable",
   "severity": "MINOR", "type": "CODE_SMELL", "hash": "h1",
   "impacts": [{"softwareQuality": "MAINTAINABILITY", "severity": "LOW"}],
   "textRange": {"startLine": 3, "endLine": 3, "startOffset": 4, "endOffset": 9}, "tags": ["unused"]},
  {"key": "I2", "rule": "python:S2068", "component": "demo:src/main.py", "message": "Hard-coded password",
   "severity": "BLOCKER", "type": "VULNERABILITY", "hash": "h2",
   "impacts": [{"softwareQuality": "SECURITY", "severity": "HIGH"}],
   "textRange": {"startLine": 7, "endLine": 8, "startOffset": 0, "endOffset": 12}},
  {"key": "I3", "rule": "python:S1192", "component": "demo:src/util.py", "message": "Duplicated literal",
   "severity": "MAJOR", "type": "CODE_SMELL"},
  {"key": "I4", "rule": "common:S1", "component": "demo", "message": "Project-wide", "severity": "INFO", "type": "CODE_SMELL"}],
  "rules": [{"key": "python:S1481", "name": "Unused local variables should be removed"},
            {"key": "python:S2068", "name": "Credentials should not be hard-coded"}]}'
task_route() {
    printf '{"path": "/api/ce/task", "query": {"id": "AZtask1"}, "responses": [%s]}' "$1"
}
TASK_DONE='{"json": {"task": {"id": "AZtask1", "status": "SUCCESS", "componentKey": "demo", "analysisId": "A1"}}}'
begin "the SARIF file"
new_case
report_task demo
routes "[$(task_route '{"json": {"task": {"status": "IN_PROGRESS"}}}, '"${TASK_DONE}"),
    {\"path\": \"/api/issues/search\", \"responses\": [{\"json\": ${ISSUES}}]}]"
run export_sarif SONAR_TOKEN=squ_abc
SARIF="${CASE}/out/sonarqube.sarif"
check "succeeds" succeeded
check "waits for the server's task" said "Waiting for ${SERVER} to process the analysis of demo (task AZtask1)"
check "reads the task with the token" requested '.path == "/api/ce/task" and .authorization == "Bearer squ_abc"'
check "searches the project's unresolved issues" \
    requested '.path == "/api/issues/search" and .query.componentKeys == "demo" and .query.resolved == "false" and .query.ps == "500" and .query.additionalFields == "rules"'
check "of the main branch" requested '.path == "/api/issues/search" and (.query | has("branch") | not)'
check "writes SARIF 2.1.0" json_is "${SARIF}" '.version' "2.1.0"
check "one result per issue in a file" json_is "${SARIF}" '.runs[0].results | length' "3"
check "names the tool" json_is "${SARIF}" '.runs[0].tool.driver.name' "SonarQube"
check "describes each rule by its name" json_is "${SARIF}" '.runs[0].tool.driver.rules[] | select(.id == "python:S2068") | .shortDescription.text' "Credentials should not be hard-coded"
check "or its key, without one" json_is "${SARIF}" '.runs[0].tool.driver.rules[] | select(.id == "python:S1192") | .shortDescription.text' "python:S1192"
check "links each rule" json_is "${SARIF}" '.runs[0].tool.driver.rules[] | select(.id == "python:S1481") | .helpUri' "${SERVER}/coding_rules?open=python%3AS1481&rule_key=python%3AS1481"
check "a high security impact is an error" json_is "${SARIF}" '.runs[0].results[] | select(.ruleId == "python:S2068") | .level' "error"
check "with a security-severity" json_is "${SARIF}" '.runs[0].tool.driver.rules[] | select(.id == "python:S2068") | .properties["security-severity"]' "8.0"
check "other rules have none" json_is "${SARIF}" '[.runs[0].tool.driver.rules[] | select(.properties | has("security-severity"))] | length' "1"
check "a low impact is a note" json_is "${SARIF}" '.runs[0].results[] | select(.ruleId == "python:S1481") | .level' "note"
check "a major issue without impacts is a warning" json_is "${SARIF}" '.runs[0].results[] | select(.ruleId == "python:S1192") | .level' "warning"
check "paths are relative to the repository's root" json_is "${SARIF}" '.runs[0].results[] | select(.ruleId == "python:S1481") | .locations[0].physicalLocation.artifactLocation.uri' "app/src/main.py"
check "columns are 1-based" json_is "${SARIF}" '.runs[0].results[] | select(.ruleId == "python:S1481") | .locations[0].physicalLocation.region | "\(.startLine):\(.startColumn)-\(.endLine):\(.endColumn)"' "3:5-3:10"
check "an issue without a range is on line 1" json_is "${SARIF}" '.runs[0].results[] | select(.ruleId == "python:S1192") | .locations[0].physicalLocation.region.startLine' "1"
check "fingerprinted with the rule and line hash" json_is "${SARIF}" '.runs[0].results[] | select(.ruleId == "python:S1481") | .partialFingerprints.primaryLocationLineHash' "python:S1481:h1:1"
check "or the issue key, without a hash" json_is "${SARIF}" '.runs[0].results[] | select(.ruleId == "python:S1192") | .partialFingerprints.primaryLocationLineHash' "python:S1192:I3:1"
check "with the category and project" json_is "${SARIF}" '.runs[0].automationDetails.id' "sonarqube/demo/"
check "leaves out the issue that is in no file" said "leaving out 1 that are not in a file"
check "exports the file's path" exported SONAR_SARIF_FILE "${SARIF}"
check "never printing the token" not_said "squ_abc"

begin "the analyzed branch or pull request"
new_case
report_task demo
routes "[$(task_route '{"json": {"task": {"status": "SUCCESS", "componentKey": "demo", "pullRequest": "42"}}}'),
    {\"path\": \"/api/issues/search\", \"responses\": [{\"json\": {\"paging\": {\"total\": 0}, \"issues\": []}}]}]"
run export_sarif SONAR_TOKEN=squ_abc
check "a pull request's issues are the pull request's" requested '.path == "/api/issues/search" and .query.pullRequest == "42"'
check "an empty analysis is an empty run" json_is "${CASE}/out/sonarqube.sarif" '.runs[0].results | length' "0"
new_case
report_task demo
routes "[$(task_route '{"json": {"task": {"status": "SUCCESS", "componentKey": "demo", "branch": "release/1.x", "branchType": "BRANCH"}}}'),
    {\"path\": \"/api/issues/search\", \"responses\": [{\"json\": {\"paging\": {\"total\": 0}, \"issues\": []}}]}]"
run export_sarif SONAR_TOKEN=squ_abc
check "a branch's issues are the branch's" requested '.path == "/api/issues/search" and .query.branch == "release/1.x"'

begin "pages and the 10,000 limit"
new_case
report_task demo
routes "[$(task_route "${TASK_DONE}"),
    {\"path\": \"/api/issues/search\", \"query\": {\"p\": \"1\"}, \"responses\": [{\"json\": {\"paging\": {\"total\": 600}, \"issues\": [{\"key\": \"A\", \"rule\": \"r:1\", \"component\": \"demo:a.py\", \"message\": \"m\", \"severity\": \"MINOR\"}]}}]},
    {\"path\": \"/api/issues/search\", \"query\": {\"p\": \"2\"}, \"responses\": [{\"json\": {\"paging\": {\"total\": 600}, \"issues\": [{\"key\": \"B\", \"rule\": \"r:1\", \"component\": \"demo:b.py\", \"message\": \"m\", \"severity\": \"MINOR\"}]}}]}]"
run export_sarif SONAR_TOKEN=squ_abc
check "reads every page" json_is "${CASE}/out/sonarqube.sarif" '[.runs[0].results[].locations[0].physicalLocation.artifactLocation.uri] | join(",")' "app/a.py,app/b.py"
new_case
report_task demo
routes "[$(task_route "${TASK_DONE}"),
    {\"path\": \"/api/issues/search\", \"responses\": [{\"json\": {\"paging\": {\"total\": 12000}, \"issues\": []}}]}]"
run export_sarif SONAR_TOKEN=squ_abc
check "more than 10,000 issues fail" failed
check "pointing at max_issues_truncate" said "Set max_issues_truncate to true"
run export_sarif SONAR_TOKEN=squ_abc max_issues_truncate=true
check "max_issues_truncate writes the first 10,000" succeeded
check "reading 20 pages, as SonarQube allows" requested '.path == "/api/issues/search" and .query.p == "20"'
check "and no more" not_requested '.query.p == "21"'

begin "when the server can't answer"
new_case
report_task demo
routes "[$(task_route '{"json": {"task": {"status": "FAILED", "errorMessage": "Out of memory"}}}')]"
run export_sarif SONAR_TOKEN=squ_abc
check "a failed task fails" failed
check "with the server's reason" said "ended FAILED: Out of memory"
new_case
report_task demo
routes "[$(task_route '{"status": 403, "json": {"errors": [{"msg": "Insufficient privileges"}]}}')]"
run export_sarif SONAR_TOKEN=squ_abc
check "a token without permission fails" failed
check "saying which permissions it needs" said "needs Browse and Execute Analysis permission on demo"
new_case
report_task demo
routes "[$(task_route '{"json": {"task": {"status": "PENDING"}}}')]"
run export_sarif SONAR_TOKEN=squ_abc wait_timeout=1
check "a task that doesn't finish in wait_timeout fails" failed
check "saying so" said "had not processed the analysis after 1 seconds"
new_case
run export_sarif SONAR_TOKEN=squ_abc
check "without a report, fails" failed
check "asking to run scan first" said "Run scan first"
new_case
report_task demo
sed -i 's|^serverUrl=.*|serverUrl=http://sonar.internal.example|' "${CASE}/repo/app/.scannerwork/report-task.txt"
run export_sarif SONAR_TOKEN=squ_abc
check "an http:// server isn't sent the token" failed
check "saying so" said "only sends the token over https"
run export_sarif SONAR_TOKEN=squ_abc "host_url=${SERVER}"
check "host_url takes the place of the report's server" failed
check "and is the one asked" said "Waiting for ${SERVER}"
new_case
report_task demo
run export_sarif
check "an empty token fails" failed

echo "=== upload_sarif"
SARIF_FIXTURE="${WORK}/fixture.sarif"
printf '{"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "SonarQube"}}, "results": [{"ruleId": "r"}]}]}\n' > "${SARIF_FIXTURE}"
UPLOAD_OK='[{"method": "POST", "path": "/repos/acme/app/code-scanning/sarifs", "responses": [{"status": 202, "json": {"id": "U1"}}]},
    {"path": "/repos/acme/app/code-scanning/sarifs/U1", "responses": [{"json": {"processing_status": "pending"}}, {"json": {"processing_status": "complete"}}]}]'
begin "what it uploads"
new_case
routes "${UPLOAD_OK}"
run upload_sarif "sarif_file=${SARIF_FIXTURE}" "api_url=${SERVER}" GITHUB_TOKEN=ghs_xyz "${GHA_PR[@]}"
check "succeeds" succeeded
check "to the build's repository" requested '.method == "POST" and .path == "/repos/acme/app/code-scanning/sarifs"'
check "with the token as a bearer token" requested '.authorization == "Bearer ghs_xyz"'
check "and GitHub's media type" requested '.accept == "application/vnd.github+json"'
check "for the pull request's merge commit" requested '.method == "POST" and (.body | fromjson | .commit_sha == "89abcdef0123456789abcdef0123456789abcdef" and .ref == "refs/pull/15/merge")'
check "waits until GitHub has processed it" said "GitHub processed it"
check "never printing the token" not_said "ghs_xyz"
body=$(jq -s -r '.[] | select(.method == "POST") | .body' "${WORK}/server.log" | jq -r .sarif | base64 -d 2> /dev/null | gunzip 2> /dev/null)
OUTPUT="uploaded: ${body}"
check "the SARIF file, gzipped and base64-encoded" test "${body}" = "$(cat "${SARIF_FIXTURE}")"
new_case
routes "${UPLOAD_OK}"
run upload_sarif "api_url=${SERVER}" GITHUB_TOKEN=ghs_xyz CIRCLECI=true CIRCLE_PROJECT_USERNAME=acme CIRCLE_PROJECT_REPONAME=app \
    CIRCLE_SHA1=0123456789abcdef0123456789abcdef01234567 CIRCLE_BRANCH=feature/login CIRCLE_PULL_REQUEST=https://github.com/acme/app/pull/42 \
    "SONAR_SARIF_FILE=${SARIF_FIXTURE}"
check "on CircleCI, a pull request's head" requested '.method == "POST" and (.body | fromjson | .commit_sha == "0123456789abcdef0123456789abcdef01234567" and .ref == "refs/pull/42/head")'
check "with the file export_sarif exported" succeeded
new_case
routes "${UPLOAD_OK}"
run upload_sarif "api_url=${SERVER}" GITHUB_TOKEN=ghs_xyz CIRCLECI=true CIRCLE_PROJECT_USERNAME=acme CIRCLE_PROJECT_REPONAME=app \
    CIRCLE_SHA1=0123456789abcdef0123456789abcdef01234567 CIRCLE_BRANCH=main "sarif_file=${SARIF_FIXTURE}"
check "a branch's ref" requested '.method == "POST" and (.body | fromjson | .ref == "refs/heads/main")'
new_case
routes "${UPLOAD_OK}"
run upload_sarif "api_url=${SERVER}" GITHUB_TOKEN=ghs_xyz "sarif_file=${SARIF_FIXTURE}" repository=acme/app \
    commit_sha=fedcba9876543210fedcba9876543210fedcba98 ref=refs/heads/release wait=false
check "the parameters win" requested '.method == "POST" and (.body | fromjson | .commit_sha == "fedcba9876543210fedcba9876543210fedcba98" and .ref == "refs/heads/release")'
check "wait false doesn't wait" not_requested '.method == "GET"'

begin "when GitHub refuses"
new_case
routes '[{"method": "POST", "path": "/repos/acme/app/code-scanning/sarifs", "responses": [{"status": 403, "json": {"message": "Advanced Security must be enabled for this repository to use code scanning."}}]}]'
run upload_sarif "sarif_file=${SARIF_FIXTURE}" "api_url=${SERVER}" GITHUB_TOKEN=ghs_xyz "${GHA_PR[@]}"
check "a 403 fails" failed
check "with GitHub's message" said "Advanced Security must be enabled"
check "explaining what code scanning needs" said "GitHub Code Security (Advanced Security) enabled"
new_case
routes '[{"method": "POST", "path": "/repos/acme/app/code-scanning/sarifs", "responses": [{"status": 202, "json": {"id": "U1"}}]},
    {"path": "/repos/acme/app/code-scanning/sarifs/U1", "responses": [{"json": {"processing_status": "failed", "errors": ["locationFromSarifResult: expected artifact location"]}}]}]'
run upload_sarif "sarif_file=${SARIF_FIXTURE}" "api_url=${SERVER}" GITHUB_TOKEN=ghs_xyz "${GHA_PR[@]}"
check "processing that fails fails" failed
check "with GitHub's errors" said "expected artifact location"

begin "what it refuses"
new_case
run upload_sarif "sarif_file=${SARIF_FIXTURE}" "${GHA_PR[@]}"
check "an empty token fails" failed
check "saying how to give one on each CI service" said "security-events: write"
run upload_sarif "sarif_file=${SARIF_FIXTURE}" GITHUB_TOKEN=ghs_xyz api_url=http://github.example.com/api/v3 "${GHA_PR[@]}"
check "an http:// API fails" failed
check "saying it must be https" said "api_url must be an https:// URL"
run upload_sarif GITHUB_TOKEN=ghs_xyz "${GHA_PR[@]}"
check "no SARIF file fails" failed
check "pointing at export_sarif" said "run export_sarif first"
printf '{"version": "2.0.0"}\n' > "${WORK}/old.sarif"
run upload_sarif "sarif_file=${WORK}/old.sarif" GITHUB_TOKEN=ghs_xyz "${GHA_PR[@]}"
check "a file that isn't SARIF 2.1.0 fails" failed
run upload_sarif "sarif_file=${SARIF_FIXTURE}" GITHUB_TOKEN=ghs_xyz "api_url=${SERVER}"
check "without CI or repository, fails" failed
check "asking for repository" said "repository must be owner/name"
run upload_sarif "sarif_file=${SARIF_FIXTURE}" GITHUB_TOKEN=ghs_xyz "api_url=${SERVER}" repository=acme/app commit_sha=abc ref=refs/heads/x
check "a short commit SHA fails" failed
run upload_sarif "sarif_file=${SARIF_FIXTURE}" GITHUB_TOKEN=ghs_xyz "api_url=${SERVER}" repository=acme/app \
    commit_sha=fedcba9876543210fedcba9876543210fedcba98 ref=main
check "a ref that isn't a full ref fails" failed

echo
if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All command checks passed."
