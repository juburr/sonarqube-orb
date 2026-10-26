#!/bin/bash
#
# Runs the SonarScanner CLI for the scan command, in the directory the step
# runs in, which holds the project's sonar-project.properties. The scanner
# gets, in this order (a later -D wins): the server URL from host_url, the
# properties setup exported (SONARQUBE_ORB_PROPERTIES), the properties
# parameter, the quality gate settings, and extra_args. The token reaches
# it as SONAR_TOKEN in its environment, never on its command line, where
# other processes could read it.
#
# The scanner writes what it sent to the server, report-task.txt, to
# .scannerwork in this directory. The scan exports where that file is
# (SONARQUBE_ORB_REPORT_TASK, which export_sarif reads), the analysis'
# dashboard URL and the server's task ID, even when the quality gate fails,
# so a later step that runs when: always can still use them.

set -euo pipefail

if [[ -z "${SCRIPT_SONARQUBE_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_SONARQUBE_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_SONARQUBE_LIB}"

# shellcheck disable=SC2034 # read by sq_host_url
declare -A SQ_PROPS=()
VERBOSE=$(sq_bool verbose "${PARAM_VERBOSE}")
QUALITY_GATE_WAIT=$(sq_bool quality_gate_wait "${PARAM_QUALITY_GATE_WAIT}")
QUALITY_GATE_TIMEOUT=$(sq_subst "${PARAM_QUALITY_GATE_TIMEOUT}")
if ! sq_match "${QUALITY_GATE_TIMEOUT}" '^[1-9][0-9]{0,5}$'; then
    echo "ERROR: quality_gate_timeout must be a number of seconds, not '${QUALITY_GATE_TIMEOUT}'." >&2
    exit 1
fi
JAVA_OPTS=$(sq_subst "${PARAM_JAVA_OPTS}")
SKIP_JRE_PROVISIONING=$(sq_bool skip_jre_provisioning "${PARAM_SKIP_JRE_PROVISIONING}")
sq_env_var_name dashboard_url_env_var "${PARAM_DASHBOARD_URL_ENV_VAR}"
sq_env_var_name task_id_env_var "${PARAM_TASK_ID_ENV_VAR}"
sq_token "${PARAM_TOKEN}"
sq_words extra_args "$(sq_subst "${PARAM_EXTRA_ARGS}")"
EXTRA=(${SQ_WORDS[@]+"${SQ_WORDS[@]}"})

# A credential on the scanner's command line would be readable by every
# process on the machine, and the report file must stay where the scan
# exports it.
refuse_property() {
    case "$1" in
        sonar.token=* | sonar.login=* | sonar.password=*)
            echo "ERROR: ${2} sets ${1%%=*}, which would put a credential on the scanner's command line." >&2
            echo "  Put the token in the environment variable the token parameter names (${SQ_TOKEN_VAR}) instead." >&2
            exit 1
            ;;
        sonar.scanner.metadataFilePath=*)
            echo "ERROR: ${2} sets sonar.scanner.metadataFilePath, which the scan sets itself, to export what the analysis sent." >&2
            exit 1
            ;;
    esac
}
for word in ${EXTRA[@]+"${EXTRA[@]}"}; do
    refuse_property "${word#-D}" extra_args
    refuse_property "${word#--define=}" extra_args
done

# The scanner, from the install command.
if ! SCANNER=$(command -v sonar-scanner); then
    echo "ERROR: sonar-scanner is not on the PATH. Run the install command in an earlier step." >&2
    exit 1
fi

ARGS=()
if [[ "${VERBOSE}" == "true" ]]; then
    ARGS+=(-X)
fi
# The server: host_url when given; otherwise the scanner reads
# SONAR_HOST_URL or the file's sonar.host.url itself.
sq_host_url "${PARAM_HOST_URL}"
if [[ "${SQ_HOST_FROM}" == "host_url" ]]; then
    ARGS+=("-Dsonar.host.url=${SQ_HOST_URL}")
fi
# What setup worked out, then the properties parameter.
while IFS= read -r line; do
    if [[ -n "${line}" ]]; then
        ARGS+=("-D${line}")
    fi
done <<< "${SONARQUBE_ORB_PROPERTIES:-}"
while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "${line}" || "${line}" == \#* ]]; then
        continue
    fi
    if ! sq_match "${line}" '^[A-Za-z0-9_.:-]+='; then
        echo "ERROR: Each line of properties must be key=value, such as sonar.exclusions=**/generated/**, not '${line}'." >&2
        exit 1
    fi
    refuse_property "${line}" properties
    ARGS+=("-D${line}")
done <<< "$(sq_subst "${PARAM_PROPERTIES}")"
# The scanner downloads a Java runtime from the server to run the analysis
# on, even when it comes with one, unless told which to use.
if [[ "${SKIP_JRE_PROVISIONING}" == "true" ]]; then
    ARGS+=(-Dsonar.scanner.skipJreProvisioning=true)
    BUNDLED_JAVA="$(dirname "$(dirname "$(readlink -f "${SCANNER}")")")/jre/bin/java"
    if [[ -x "${BUNDLED_JAVA}" ]]; then
        ARGS+=("-Dsonar.scanner.javaExePath=${BUNDLED_JAVA}")
    fi
fi
if [[ "${QUALITY_GATE_WAIT}" == "true" ]]; then
    ARGS+=(-Dsonar.qualitygate.wait=true "-Dsonar.qualitygate.timeout=${QUALITY_GATE_TIMEOUT}")
fi
REPORT_TASK="$(pwd)/.scannerwork/report-task.txt"
ARGS+=("-Dsonar.scanner.metadataFilePath=${REPORT_TASK}")
ARGS+=(${EXTRA[@]+"${EXTRA[@]}"})

if [[ -z "${SQ_TOKEN}" ]]; then
    echo "ERROR: ${SQ_TOKEN_VAR}, the environment variable the token parameter names, is empty." >&2
    echo "  Create a token in SonarQube (My Account > Security) and add it to a CircleCI context, or a GitHub secret, as ${SQ_TOKEN_VAR}." >&2
    exit 1
fi

# A report from an earlier analysis must not pass for this one's.
mkdir -p "${REPORT_TASK%/*}"
rm -f "${REPORT_TASK}"

echo "Running $("${SCANNER}" --version 2> /dev/null | sed -n 's/.*\(SonarScanner CLI [0-9.]*\).*/\1/p' | head -n 1 || true) in $(pwd)"
for arg in "${ARGS[@]}"; do
    case "${arg}" in
        -D*) sq_print_property "${arg%%=*}" "${arg#*=}" ;;
        *) printf '  %s\n' "${arg}" ;;
    esac
done
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
RC=0
# The token and Java options reach the scanner in its environment, exported
# in a subshell, so they are on no command line. The launcher's Java
# runtime reads SONAR_SCANNER_OPTS, and the scanner passes
# SONAR_SCANNER_JAVA_OPTS (sonar.scanner.javaOpts) to the one the analysis
# runs on.
(
    export SONAR_TOKEN="${SQ_TOKEN}"
    if [[ -n "${JAVA_OPTS}" ]]; then
        export SONAR_SCANNER_OPTS="${JAVA_OPTS}" SONAR_SCANNER_JAVA_OPTS="${JAVA_OPTS}"
    fi
    exec "${SCANNER}" "${ARGS[@]}"
) 2>&1 | tee "${WORK}/scan.log" || RC=${PIPESTATUS[0]}

# What the scanner sent, when it got that far.
DASHBOARD="" TASK_ID=""
if [[ -s "${REPORT_TASK}" ]]; then
    DASHBOARD=$(sed -n 's/^dashboardUrl=//p' "${REPORT_TASK}" | head -n 1)
    TASK_ID=$(sed -n 's/^ceTaskId=//p' "${REPORT_TASK}" | head -n 1)
    sq_export SONARQUBE_ORB_REPORT_TASK "${REPORT_TASK}"
    sq_export "${PARAM_DASHBOARD_URL_ENV_VAR}" "${DASHBOARD}"
    sq_export "${PARAM_TASK_ID_ENV_VAR}" "${TASK_ID}"
fi

if [[ "${RC}" -ne 0 ]]; then
    if grep -q 'QUALITY GATE STATUS: FAILED' "${WORK}/scan.log"; then
        echo "ERROR: The analysis failed its quality gate${DASHBOARD:+: see ${DASHBOARD}}." >&2
    elif grep -q 'Quality Gate check timeout exceeded' "${WORK}/scan.log"; then
        echo "ERROR: The server did not finish processing the analysis within quality_gate_timeout (${QUALITY_GATE_TIMEOUT} seconds)." >&2
    elif grep -q 'Developer Edition or above is required' "${WORK}/scan.log"; then
        echo "ERROR: The server is Community Build, which only analyzes the main branch, and refuses branch and pull request properties." >&2
        echo "  Set setup's branch_analysis to auto or false, and remove sonar.branch.name and sonar.pullrequest.* from the properties." >&2
    else
        echo "ERROR: The SonarScanner CLI failed (exit code ${RC}); its log above says why. Set verbose to true for more detail." >&2
    fi
    exit 1
fi
if [[ -z "${DASHBOARD}" ]]; then
    echo "ERROR: The scanner finished without writing ${REPORT_TASK}, so nothing says what it sent." >&2
    exit 1
fi
echo "The analysis went to the server${TASK_ID:+ as task ${TASK_ID}}. Its results: ${DASHBOARD}"
echo "Exported ${PARAM_DASHBOARD_URL_ENV_VAR}, ${PARAM_TASK_ID_ENV_VAR} and SONARQUBE_ORB_REPORT_TASK for later steps."
