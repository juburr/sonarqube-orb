#!/bin/bash
#
# Prepares a SonarQube analysis for the setup command: checks the project's
# properties file and checkout, works out from CircleCI's or GitHub Actions'
# environment whether this build analyzes a branch or a pull request, and
# exports the analysis properties that follow as SONARQUBE_ORB_PROPERTIES,
# one key=value per line, which the scan command passes to the scanner with
# -D. The properties file itself is never changed.
#
# Branch and pull request analysis need SonarQube Server's Developer Edition
# or above, or SonarQube Cloud: Community Build refuses an analysis with
# branch or pull request properties. branch_analysis auto asks the server
# which edition it is, and leaves them out for Community Build.

set -euo pipefail

if [[ -z "${SCRIPT_SONARQUBE_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_SONARQUBE_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_SONARQUBE_LIB}"

declare -A SQ_PROPS=()
PROPERTIES_FILE=$(sq_subst "${PARAM_PROPERTIES_FILE}")
REQUIRE_PROPERTIES_FILE=$(sq_bool require_properties_file "${PARAM_REQUIRE_PROPERTIES_FILE}")
PROJECT_KEY=$(sq_subst "${PARAM_PROJECT_KEY}")
BRANCH_NAME=$(sq_subst "${PARAM_BRANCH_NAME}")
PR_KEY=$(sq_subst "${PARAM_PULL_REQUEST_KEY}")
PR_BRANCH=$(sq_subst "${PARAM_PULL_REQUEST_BRANCH}")
PR_BASE=$(sq_subst "${PARAM_PULL_REQUEST_BASE}")
case "${PARAM_BRANCH_ANALYSIS}" in
    auto | true | false) BRANCH_ANALYSIS=${PARAM_BRANCH_ANALYSIS} ;;
    1) BRANCH_ANALYSIS=true ;;
    0) BRANCH_ANALYSIS=false ;;
    *)
        echo "ERROR: branch_analysis must be auto, true or false, not '${PARAM_BRANCH_ANALYSIS}'." >&2
        exit 1
        ;;
esac
sq_token "${PARAM_TOKEN}"

ERRORS=0
error() {
    printf 'ERROR: %s\n' "$1" >&2
    shift
    if [[ $# -gt 0 ]]; then
        printf '  %s\n' "$@" >&2
    fi
    ERRORS=$((ERRORS + 1))
}
warn() {
    printf 'WARN: %s\n' "$1" >&2
    shift
    if [[ $# -gt 0 ]]; then
        printf '  %s\n' "$@" >&2
    fi
}

# The properties file, which the scanner reads from the directory it runs in.
if [[ -z "${PROPERTIES_FILE}" ]]; then
    PROPERTIES_FILE="sonar-project.properties"
fi
FILE_STATE="none"
if [[ -f "${PROPERTIES_FILE}" ]]; then
    sq_properties_read "${PROPERTIES_FILE}"
    FILE_STATE="read"
elif [[ -e "${PROPERTIES_FILE}" ]]; then
    error "${PROPERTIES_FILE} is not a file."
elif [[ "${REQUIRE_PROPERTIES_FILE}" == "true" ]]; then
    error "There is no ${PROPERTIES_FILE} in $(pwd)." \
        "The scanner reads the project's settings from it: add one with at least sonar.projectKey (and" \
        "sonar.organization for SonarQube Cloud), run setup in the directory that has it (working_dir), or" \
        "set require_properties_file to false and give project_key and any other settings to scan."
fi
if [[ "${PROPERTIES_FILE}" != "sonar-project.properties" && "${FILE_STATE}" == "read" ]]; then
    PROPERTIES_ARG="project.settings=${PROPERTIES_FILE}"
else
    PROPERTIES_ARG=""
fi

# The project key: the parameter, or the file's.
if [[ -z "${PROJECT_KEY}" ]]; then
    PROJECT_KEY=${SQ_PROPS[sonar.projectKey]:-}
    KEY_FROM=${PROPERTIES_FILE}
else
    KEY_FROM="project_key"
fi
if [[ -z "${PROJECT_KEY}" ]]; then
    if [[ "${FILE_STATE}" == "read" ]]; then
        error "${PROPERTIES_FILE} has no sonar.projectKey, which every analysis needs. Add it, or set project_key."
    elif [[ "${REQUIRE_PROPERTIES_FILE}" == "false" ]]; then
        error "Without ${PROPERTIES_FILE}, set project_key: every analysis needs one."
    fi
elif [[ "${PROJECT_KEY}" == *\$\{* ]]; then
    warn "The project key '${PROJECT_KEY}' (${KEY_FROM}) holds a placeholder this step can't resolve, so it can't check it."
elif ! sq_match "${PROJECT_KEY}" '^[A-Za-z0-9_.:-]+$' || sq_match "${PROJECT_KEY}" '^[0-9]+$' || [[ "${#PROJECT_KEY}" -gt 400 ]]; then
    error "The project key '${PROJECT_KEY}' (${KEY_FROM}) is not one SonarQube accepts:" \
        "up to 400 letters, digits, '-', '_', '.' and ':', with at least one that isn't a digit."
fi

# Credentials committed to the file.
for key in "${!SQ_PROPS[@]}"; do
    if sq_secret_key "${key}" && [[ -n "${SQ_PROPS[${key}]}" ]]; then
        warn "${PROPERTIES_FILE} sets ${key}, a credential, in the repository. Remove it, rotate it," \
            "and keep the token in a CircleCI context or GitHub secret named by the token parameter instead."
    fi
done

# The directories sonar.sources and sonar.tests name, relative to the
# project's base directory.
BASE_DIR="."
if [[ -n "${SQ_PROPS[sonar.projectBaseDir]:-}" && "${SQ_PROPS[sonar.projectBaseDir]}" != *\$\{* ]]; then
    BASE_DIR=${SQ_PROPS[sonar.projectBaseDir]}
    if [[ ! -d "${BASE_DIR}" ]]; then
        error "sonar.projectBaseDir in ${PROPERTIES_FILE} names ${BASE_DIR}, which is not a directory here."
        BASE_DIR="."
    fi
fi
for key in sonar.sources sonar.tests; do
    if [[ -z "${SQ_PROPS[${key}]+set}" ]]; then
        continue
    fi
    IFS=',' read -r -a paths <<< "${SQ_PROPS[${key}]}"
    for path in ${paths[@]+"${paths[@]}"}; do
        path="${path#"${path%%[![:space:]]*}"}"
        path="${path%"${path##*[![:space:]]}"}"
        # A placeholder this step couldn't resolve is the scanner's to check.
        if [[ -z "${path}" || "${path}" == *\$\{* ]]; then
            continue
        fi
        if [[ "${path}" == /* ]]; then
            full=${path}
        else
            full="${BASE_DIR%/}/${path}"
        fi
        if [[ ! -e "${full}" ]]; then
            error "${key} in ${PROPERTIES_FILE} names ${path}, which does not exist in $(cd "${BASE_DIR}" && pwd)." \
                "The scanner would stop on it. Paths are relative to the project's base directory, and separated by commas."
        fi
    done
done

# The server.
sq_host_url "${PARAM_HOST_URL}"
if [[ -z "${SQ_HOST_URL}" ]]; then
    warn "No server URL is set (host_url, SONAR_HOST_URL or sonar.host.url), so the scanner will send the analysis" \
        "to SonarQube Cloud (https://sonarcloud.io). Set host_url, or SONAR_HOST_URL in a context, for SonarQube Server."
    CLOUD=true
elif sq_cloud "${SQ_HOST_URL}"; then
    CLOUD=true
else
    CLOUD=false
fi
if [[ "${CLOUD}" == "true" && -z "${SQ_PROPS[sonar.organization]:-}" && -z "${SONAR_ORGANIZATION:-}" ]]; then
    warn "SonarQube Cloud needs the organization's key: set sonar.organization in ${PROPERTIES_FILE}, or pass it to scan in properties."
fi

# The build: its CI service, branch and pull request, which the parameters
# can replace.
sq_ci_context
if [[ -n "${PR_KEY}" || -n "${PR_BRANCH}" ]]; then
    SQ_CI_PR_KEY=${PR_KEY:-${SQ_CI_PR_KEY}}
    SQ_CI_PR_BRANCH=${PR_BRANCH:-${SQ_CI_PR_BRANCH}}
fi
if [[ -n "${BRANCH_NAME}" ]]; then
    SQ_CI_BRANCH=${BRANCH_NAME}
    SQ_CI_PR_KEY=""
    SQ_CI_PR_BRANCH=""
fi
if [[ -n "${PR_BASE}" ]]; then
    SQ_CI_PR_BASE=${PR_BASE}
fi
if [[ -n "${SQ_CI_PR_KEY}" && -z "${SQ_CI_PR_BRANCH}" ]]; then
    error "This build is for pull request ${SQ_CI_PR_KEY}, but its branch is unknown. Set pull_request_branch."
fi
if [[ -n "${SQ_CI_PR_BRANCH}" && -z "${SQ_CI_PR_KEY}" ]]; then
    error "pull_request_branch is set, but the pull request's number is unknown. Set pull_request_key too."
fi
if [[ -n "${SQ_CI_PR_KEY}" ]] && ! sq_match "${SQ_CI_PR_KEY}" '^[A-Za-z0-9_.-]+$'; then
    error "The pull request key '${SQ_CI_PR_KEY}' is not a pull request number."
fi
if [[ -n "${SQ_CI_PR_KEY}" ]]; then
    BUILD="pull request ${SQ_CI_PR_KEY} (${SQ_CI_PR_BRANCH} into ${SQ_CI_PR_BASE:-the main branch})"
elif [[ -n "${SQ_CI_BRANCH}" ]]; then
    BUILD="branch ${SQ_CI_BRANCH}"
elif [[ -n "${SQ_CI_TAG}" ]]; then
    BUILD="tag ${SQ_CI_TAG}"
else
    BUILD="no branch or pull request this step can tell"
fi

# Whether to send branch and pull request properties.
SEND_BRANCH=false
REASON=""
if [[ -z "${SQ_CI_PR_KEY}" && -z "${SQ_CI_BRANCH}" ]]; then
    REASON="there is no branch or pull request to name"
    if [[ "${BRANCH_ANALYSIS}" == "true" ]]; then
        error "branch_analysis is true, but this build has no branch or pull request: set branch_name, or" \
            "pull_request_key and pull_request_branch."
    elif [[ -n "${SQ_CI_TAG}" ]]; then
        warn "This build is for tag ${SQ_CI_TAG}, with no branch, so its analysis goes to the project's main branch."
    fi
elif [[ "${BRANCH_ANALYSIS}" == "false" ]]; then
    REASON="branch_analysis is false"
elif [[ "${BRANCH_ANALYSIS}" == "true" ]]; then
    SEND_BRANCH=true
    REASON="branch_analysis is true"
elif [[ "${CLOUD}" == "true" ]]; then
    SEND_BRANCH=true
    REASON="SonarQube Cloud analyzes branches and pull requests"
else
    # Community Build refuses branch and pull request properties, so ask the
    # server which edition it is.
    EDITION=""
    if [[ -z "${SQ_HOST_URL}" ]]; then
        :
    else
        sq_curl_init
        WORK=$(mktemp -d)
        trap 'rm -rf "${WORK}"' EXIT
        # The token only goes over https, or to this machine.
        SQ_AUTH_FILE=""
        SECURE=false
        if [[ "${SQ_HOST_URL}" == https://* ]] || sq_loopback "${SQ_HOST_URL}"; then
            SECURE=true
        fi
        if [[ -n "${SQ_TOKEN}" && "${SECURE}" == "true" ]]; then
            SQ_AUTH_FILE="${WORK}/auth"
            sq_auth_header "${SQ_AUTH_FILE}" Authorization "Bearer ${SQ_TOKEN}"
        fi
        # api/navigation/global names the edition, but needs the token on
        # SonarQube Server. Without it, the version, which needs no token,
        # still tells Community Build (24.x to 26.x and on) from SonarQube
        # Server (2025.x and on, or 10.x and before, which can't be told
        # apart), as the scanner itself does.
        CODE=""
        if [[ "${SECURE}" == "true" ]] && CODE=$(sq_api "${SQ_HOST_URL}/api/navigation/global" "${WORK}/global.json") \
            && [[ "${CODE}" == 200 ]]; then
            EDITION=$(sed -n 's/.*"edition" *: *"\([A-Za-z]*\)".*/\1/p' "${WORK}/global.json" | head -n 1)
        fi
        if [[ -z "${EDITION}" ]] && VERSION_CODE=$(SQ_AUTH_FILE="" sq_api "${SQ_HOST_URL}/api/server/version" "${WORK}/version.txt") \
            && [[ "${VERSION_CODE}" == 200 ]]; then
            MAJOR=$(sed -n '1s/^\([0-9]*\)\..*/\1/p' "${WORK}/version.txt")
            if [[ -n "${MAJOR}" && "${MAJOR}" -gt 10 && "${MAJOR}" -lt 2000 ]]; then
                EDITION=community
            fi
        fi
        if [[ -z "${EDITION}" && "${SECURE}" == "false" ]]; then
            warn "The server URL is http://, and this orb only sends the token over https, so it asked the server" \
                "only for its version, which didn't tell its edition. Set branch_analysis to true or false."
        fi
        if [[ -z "${EDITION}" && "${SECURE}" == "true" ]]; then
            warn "Could not tell which edition ${SQ_HOST_URL} is (api/navigation/global answered HTTP ${CODE:-nothing}${SQ_TOKEN:+, with the token in ${SQ_TOKEN_VAR}})."
        fi
    fi
    case "${EDITION,,}" in
        community)
            REASON="the server is Community Build, which analyzes the main branch only"
            if [[ -n "${SQ_CI_PR_KEY}" ]]; then
                warn "Community Build has no pull request analysis, so the analysis of pull request ${SQ_CI_PR_KEY}" \
                    "replaces the main branch's. Scan only the main branch there, or use Developer Edition or above."
            fi
            ;;
        "")
            SEND_BRANCH=true
            REASON="the server's edition is unknown (set branch_analysis to false for Community Build)"
            ;;
        *)
            SEND_BRANCH=true
            REASON="the server is ${EDITION} edition"
            ;;
    esac
fi

# The properties the scan passes on with -D, which win over the file's.
PROPS=()
if [[ "${KEY_FROM}" == "project_key" && -n "${PROJECT_KEY}" ]]; then
    PROPS+=("sonar.projectKey=${PROJECT_KEY}")
fi
if [[ -n "${PROPERTIES_ARG}" ]]; then
    PROPS+=("${PROPERTIES_ARG}")
fi
if [[ "${SEND_BRANCH}" == "true" ]]; then
    if [[ -n "${SQ_CI_PR_KEY}" ]]; then
        PROPS+=("sonar.pullrequest.key=${SQ_CI_PR_KEY}" "sonar.pullrequest.branch=${SQ_CI_PR_BRANCH}")
        if [[ -n "${SQ_CI_PR_BASE}" ]]; then
            PROPS+=("sonar.pullrequest.base=${SQ_CI_PR_BASE}")
        fi
    else
        PROPS+=("sonar.branch.name=${SQ_CI_BRANCH}")
    fi
fi
for key in sonar.branch.name sonar.pullrequest.key sonar.pullrequest.branch sonar.pullrequest.base; do
    if [[ -n "${SQ_PROPS[${key}]+set}" ]]; then
        if [[ "${SEND_BRANCH}" == "true" ]]; then
            warn "${PROPERTIES_FILE} sets ${key}, which this setup replaces for the scan. Remove it from the file."
        else
            warn "${PROPERTIES_FILE} sets ${key}, which the scan will send as is. Remove it from the file," \
                "since the branch or pull request differs from build to build."
        fi
    fi
done

# The checkout: SonarQube needs its history for blame, and for a pull
# request, the branch it goes into.
if command -v git > /dev/null 2>&1 && git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    if [[ "$(git rev-parse --is-shallow-repository 2> /dev/null || true)" == "true" ]]; then
        warn "This checkout is shallow, so SonarQube can't blame lines or tell new code from old." \
            "Fetch the whole history: on GitHub Actions, give actions/checkout fetch-depth: 0."
    fi
    if [[ "${SEND_BRANCH}" == "true" && -n "${SQ_CI_PR_KEY}" && -n "${SQ_CI_PR_BASE}" ]] \
        && ! git rev-parse --verify --quiet "refs/remotes/origin/${SQ_CI_PR_BASE}" > /dev/null \
        && ! git rev-parse --verify --quiet "refs/heads/${SQ_CI_PR_BASE}" > /dev/null; then
        warn "The checkout has no ${SQ_CI_PR_BASE}, the branch pull request ${SQ_CI_PR_KEY} goes into, so SonarQube" \
            "can't tell which lines it changes. Fetch it first, such as with git fetch origin ${SQ_CI_PR_BASE}."
    fi
fi

echo "SonarQube analysis of ${PROJECT_KEY:-an unknown project} in $(pwd)"
echo "  properties file: ${PROPERTIES_FILE} ($([[ "${FILE_STATE}" == "read" ]] && echo "${#SQ_PROPS[@]} properties" || echo "none"))"
echo "  server:          ${SQ_HOST_URL:-SonarQube Cloud, by default}${SQ_HOST_FROM:+ (from ${SQ_HOST_FROM})}"
echo "  token:           $([[ -n "${SQ_TOKEN}" ]] && echo "set, in ${SQ_TOKEN_VAR}" || echo "${SQ_TOKEN_VAR} is empty")"
echo "  build:           ${SQ_CI:-no CI service this step knows}, ${BUILD}"
if [[ "${SEND_BRANCH}" == "true" ]]; then
    echo "  analysis:        $([[ -n "${SQ_CI_PR_KEY}" ]] && echo "pull request ${SQ_CI_PR_KEY}" || echo "branch ${SQ_CI_BRANCH}"), since ${REASON}"
else
    echo "  analysis:        the main branch, since ${REASON}"
fi
if [[ "${FILE_STATE}" == "read" ]]; then
    echo "${PROPERTIES_FILE} sets:"
    while IFS= read -r key; do
        sq_print_property "${key}" "${SQ_PROPS[${key}]}"
    done < <(printf '%s\n' "${!SQ_PROPS[@]}" | LC_ALL=C sort)
fi
if [[ "${#PROPS[@]}" -gt 0 ]]; then
    echo "The scan adds:"
    for prop in "${PROPS[@]}"; do
        sq_print_property "${prop%%=*}" "${prop#*=}"
    done
fi

if [[ "${ERRORS}" -gt 0 ]]; then
    echo "ERROR: The analysis is not set up: fix the $([[ "${ERRORS}" -eq 1 ]] && echo "problem" || echo "${ERRORS} problems") above." >&2
    exit 1
fi
if [[ "${#PROPS[@]}" -gt 0 ]]; then
    sq_export SONARQUBE_ORB_PROPERTIES "$(printf '%s\n' "${PROPS[@]}")"
else
    sq_export SONARQUBE_ORB_PROPERTIES ""
fi
echo "The scan command will pass these on."
