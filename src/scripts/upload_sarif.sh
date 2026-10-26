#!/bin/bash
#
# Uploads a SARIF file to GitHub code scanning for the upload_sarif command,
# through the REST API (POST /repos/{owner}/{repo}/code-scanning/sarifs), so
# it works from CircleCI as well as GitHub Actions, and on GitHub Enterprise
# Server. GitHub accepts it for public repositories on github.com, and for
# private ones and GitHub Enterprise Server only with GitHub Code Security
# (Advanced Security) enabled. The token needs the security_events scope:
# security-events: write for GITHUB_TOKEN, or "Code scanning alerts" read
# and write for a fine-grained token.
#
# The commit and ref default to the build's: on GitHub Actions GITHUB_SHA
# and GITHUB_REF (refs/pull/<n>/merge for a pull request), on CircleCI
# CIRCLE_SHA1 and refs/heads/<branch>, or refs/pull/<n>/head for a pull
# request. It then waits for GitHub to process the upload, and fails when
# GitHub rejects it.

set -euo pipefail

if [[ -z "${SCRIPT_SONARQUBE_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_SONARQUBE_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_SONARQUBE_LIB}"

SARIF=$(sq_subst "${PARAM_SARIF_FILE}")
if [[ -z "${SARIF}" ]]; then
    SARIF=${SONAR_SARIF_FILE:-}
fi
REPOSITORY=$(sq_subst "${PARAM_REPOSITORY}")
API_URL=$(sq_subst "${PARAM_API_URL}")
COMMIT=$(sq_subst "${PARAM_COMMIT_SHA}")
REF=$(sq_subst "${PARAM_REF}")
WAIT=$(sq_bool wait "${PARAM_WAIT}")
WAIT_TIMEOUT=$(sq_subst "${PARAM_WAIT_TIMEOUT}")
if ! sq_match "${WAIT_TIMEOUT}" '^[1-9][0-9]{0,4}$'; then
    echo "ERROR: wait_timeout must be a number of seconds, not '${WAIT_TIMEOUT}'." >&2
    exit 1
fi
sq_env_var_name github_token "${PARAM_GITHUB_TOKEN}"
# Read here, with xtrace off, so the token is never printed.
set +o xtrace
GITHUB_TOKEN_VALUE=${!PARAM_GITHUB_TOKEN:-}

for tool in jq gzip base64; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
        echo "ERROR: upload_sarif needs ${tool}, which is not on the PATH. Install it in an earlier step." >&2
        exit 1
    fi
done
if [[ -z "${SARIF}" ]]; then
    echo "ERROR: No SARIF file to upload: set sarif_file, or run export_sarif first, which exports SONAR_SARIF_FILE." >&2
    exit 1
fi
if [[ ! -f "${SARIF}" ]]; then
    echo "ERROR: The SARIF file ${SARIF} does not exist." >&2
    exit 1
fi
if ! jq -e '.version == "2.1.0" and (.runs | type == "array")' "${SARIF}" > /dev/null 2>&1; then
    echo "ERROR: ${SARIF} is not a SARIF 2.1.0 file." >&2
    exit 1
fi
if [[ -z "${GITHUB_TOKEN_VALUE}" ]]; then
    echo "ERROR: ${PARAM_GITHUB_TOKEN}, the environment variable github_token names, is empty." >&2
    echo "  On GitHub Actions, pass the job's token (\${{ github.token }}) with permissions security-events: write." >&2
    echo "  On CircleCI, add a GitHub token with the security_events scope (or, fine-grained, Code scanning alerts:" >&2
    echo "  read and write) to a context, as ${PARAM_GITHUB_TOKEN}." >&2
    exit 1
fi

# Where to upload it.
sq_ci_context
if [[ -z "${REPOSITORY}" ]]; then
    REPOSITORY=${SQ_CI_REPOSITORY}
fi
if ! sq_match "${REPOSITORY}" '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    echo "ERROR: repository must be owner/name${REPOSITORY:+, not ${REPOSITORY}}." >&2
    echo "  Set it when CI doesn't say which GitHub repository this build is for." >&2
    exit 1
fi
if [[ -z "${API_URL}" ]]; then
    API_URL=${GITHUB_API_URL:-https://api.github.com}
fi
API_URL=${API_URL%/}
# The token only goes over https, or to this machine.
if ! sq_match "${API_URL}" '^https?://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$' \
    || { [[ "${API_URL}" != https://* ]] && ! sq_loopback "${API_URL}"; }; then
    echo "ERROR: api_url must be an https:// URL, such as https://api.github.com or https://github.example.com/api/v3, not '${API_URL}'." >&2
    exit 1
fi
if [[ -z "${COMMIT}" ]]; then
    COMMIT=${SQ_CI_SHA}
fi
if ! sq_match "${COMMIT}" '^[0-9a-f]{40}([0-9a-f]{24})?$'; then
    echo "ERROR: commit_sha must be the full commit SHA${COMMIT:+, not ${COMMIT}}. Set it when CI doesn't say which commit this build is for." >&2
    exit 1
fi
if [[ -z "${REF}" ]]; then
    if [[ "${SQ_CI}" == "GitHub Actions" && "${GITHUB_REF:-}" == refs/* ]]; then
        REF=${GITHUB_REF}
    elif [[ -n "${SQ_CI_PR_KEY}" ]]; then
        REF="refs/pull/${SQ_CI_PR_KEY}/head"
    elif [[ -n "${SQ_CI_BRANCH}" ]]; then
        REF="refs/heads/${SQ_CI_BRANCH}"
    elif [[ -n "${SQ_CI_TAG}" ]]; then
        REF="refs/tags/${SQ_CI_TAG}"
    fi
fi
if ! sq_match "${REF}" '^refs/(heads|tags)/[^[:space:]]+$' && ! sq_match "${REF}" '^refs/pull/[0-9]+/(head|merge)$'; then
    echo "ERROR: ref must be refs/heads/<branch>, refs/tags/<tag> or refs/pull/<number>/head${REF:+, not ${REF}}." >&2
    echo "  Set it when CI doesn't say which branch this build is for." >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
# GitHub takes the file gzipped and base64-encoded, up to 10 MB gzipped.
gzip -c "${SARIF}" > "${WORK}/sarif.gz"
SIZE=$(wc -c < "${WORK}/sarif.gz")
if [[ "${SIZE}" -gt 10485760 ]]; then
    echo "ERROR: ${SARIF} is ${SIZE} bytes gzipped, more than the 10 MB GitHub code scanning accepts." >&2
    exit 1
fi
base64 < "${WORK}/sarif.gz" | tr -d '\n' > "${WORK}/sarif.b64"
jq -n --arg commit "${COMMIT}" --arg ref "${REF}" --rawfile sarif "${WORK}/sarif.b64" \
    '{commit_sha: $commit, ref: $ref, sarif: $sarif, tool_name: "SonarQube"}' > "${WORK}/body.json"
RESULTS=$(jq '[.runs[].results | length] | add // 0' "${SARIF}")

sq_curl_init
SQ_AUTH_FILE="${WORK}/auth"
(
    umask 077
    printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' \
        "${GITHUB_TOKEN_VALUE}" > "${SQ_AUTH_FILE}"
)
UPLOAD_URL="${API_URL}/repos/${REPOSITORY}/code-scanning/sarifs"
echo "Uploading ${SARIF} (${RESULTS} results) to GitHub code scanning for ${REPOSITORY}, ${REF} at ${COMMIT}..."
CODE=$(sq_api "${UPLOAD_URL}" "${WORK}/upload.json" -X POST -H "Content-Type: application/json" \
    --data-binary "@${WORK}/body.json") || CODE=""

# explain FILE: GitHub's error message in FILE, if any.
explain() {
    jq -r '.message // empty' "$1" 2> /dev/null | head -n 1 || true
}
case "${CODE}" in
    202) ;;
    403 | 404)
        echo "ERROR: GitHub refused the upload (HTTP ${CODE}): $(explain "${WORK}/upload.json")" >&2
        echo "  Code scanning takes uploads for public repositories on github.com, and for private repositories and" >&2
        echo "  GitHub Enterprise Server only with GitHub Code Security (Advanced Security) enabled. The token needs" >&2
        echo "  the security_events scope (security-events: write for GITHUB_TOKEN), and access to ${REPOSITORY}." >&2
        exit 1
        ;;
    "")
        echo "ERROR: Could not reach ${UPLOAD_URL}." >&2
        exit 1
        ;;
    *)
        echo "ERROR: GitHub refused the upload (HTTP ${CODE}): $(explain "${WORK}/upload.json")" >&2
        exit 1
        ;;
esac
ID=$(jq -r '.id // empty' "${WORK}/upload.json")
echo "GitHub accepted the upload${ID:+ as ${ID}}."
if [[ "${WAIT}" == "false" || -z "${ID}" ]]; then
    exit 0
fi

# GitHub processes the file afterwards, and says how it went.
DEADLINE=$((SECONDS + WAIT_TIMEOUT))
DELAY=2
while true; do
    CODE=$(sq_api "${UPLOAD_URL}/${ID}" "${WORK}/status.json") || CODE=""
    STATUS=""
    if [[ "${CODE}" == 200 ]]; then
        STATUS=$(jq -r '.processing_status // empty' "${WORK}/status.json")
    fi
    case "${STATUS}" in
        complete)
            echo "GitHub processed it: the alerts are in the repository's Security tab, under code scanning."
            exit 0
            ;;
        failed)
            echo "ERROR: GitHub could not process the upload:" >&2
            jq -r '.errors[]? | "  " + .' "${WORK}/status.json" >&2
            exit 1
            ;;
    esac
    if [[ "${SECONDS}" -ge "${DEADLINE}" ]]; then
        echo "ERROR: GitHub had not processed the upload after ${WAIT_TIMEOUT} seconds (last status: ${STATUS:-HTTP ${CODE:-none}})." >&2
        exit 1
    fi
    sleep "${DELAY}"
    if [[ "${DELAY}" -lt 10 ]]; then
        DELAY=$((DELAY * 2))
    fi
done
