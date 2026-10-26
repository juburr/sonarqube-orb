#!/usr/bin/env bash
#
# Prepares a fresh SonarQube Community Build container for test-deploy.yml
# and the GitHub Actions workflow, through its Web API on this machine:
#
#   bash tests/sonarqube_server.sh token URL TOKEN_FILE
#       Waits until the server is up, changes the admin password (a fresh
#       server only answers the API with it changed), and writes a new user
#       token for the admin to TOKEN_FILE.
#   bash tests/sonarqube_server.sh failing-gate URL TOKEN_FILE PROJECT
#       Makes PROJECT's quality gate one that fails every analysis: lines of
#       code greater than 0.
#
# The admin's credentials and the token go to curl in a config file, never
# on its command line.

set -euo pipefail

ACTION=${1:-}
URL=${2:-}
TOKEN_FILE=${3:-}
if [[ -z "${URL}" || -z "${TOKEN_FILE}" ]]; then
    echo "ERROR: Usage: bash tests/sonarqube_server.sh token|failing-gate URL TOKEN_FILE [PROJECT]" >&2
    exit 2
fi
URL=${URL%/}
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
umask 077

# api CONFIG METHOD PATH [CURL_ARG...]: calls the Web API with the
# credentials in CONFIG, and prints the response.
api() {
    local config=$1 method=$2 path=$3
    shift 3
    curl -sS --fail-with-body -K "${config}" -X "${method}" "$@" "${URL}/${path}"
}

case "${ACTION}" in
    token)
        echo "Waiting for ${URL} to be up..."
        status=""
        for _ in $(seq 1 120); do
            status=$(curl -sS --max-time 10 "${URL}/api/system/status" 2> /dev/null | sed -n 's/.*"status":"\([A-Z_]*\)".*/\1/p' || true)
            if [[ "${status}" == "UP" ]]; then
                break
            fi
            sleep 5
        done
        if [[ "${status}" != "UP" ]]; then
            echo "ERROR: ${URL} is not up after 10 minutes (status: ${status:-no answer})." >&2
            exit 1
        fi
        # The password needs 12 characters with an upper and lower case
        # letter, a digit and a symbol.
        password="Orb-$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')-Aa1!"
        printf 'user = "admin:admin"\n' > "${WORK}/admin"
        # Search indexes can still be starting just after the server says UP.
        for attempt in 1 2 3 4 5 6; do
            if api "${WORK}/admin" POST api/users/change_password --data-urlencode login=admin \
                --data-urlencode previousPassword=admin --data-urlencode "password=${password}" > /dev/null; then
                break
            fi
            if [[ "${attempt}" -eq 6 ]]; then
                echo "ERROR: Could not change the admin password." >&2
                exit 1
            fi
            sleep 10
        done
        printf 'user = "admin:%s"\n' "${password}" > "${WORK}/admin"
        api "${WORK}/admin" POST api/user_tokens/generate --data-urlencode "name=orb-test-$(date +%s)" \
            --data-urlencode type=USER_TOKEN > "${WORK}/token.json"
        token=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "${WORK}/token.json")
        if [[ -z "${token}" ]]; then
            echo "ERROR: The server did not return a token." >&2
            exit 1
        fi
        printf '%s' "${token}" > "${TOKEN_FILE}"
        echo "Wrote a user token to ${TOKEN_FILE}."
        ;;
    failing-gate)
        project=${4:-}
        if [[ -z "${project}" ]]; then
            echo "ERROR: failing-gate needs the project's key." >&2
            exit 2
        fi
        printf 'header = "Authorization: Bearer %s"\n' "$(cat "${TOKEN_FILE}")" > "${WORK}/token"
        api "${WORK}/token" POST api/qualitygates/create --data-urlencode name=orb-fails > /dev/null
        api "${WORK}/token" POST api/qualitygates/create_condition --data-urlencode gateName=orb-fails \
            --data-urlencode metric=ncloc --data-urlencode op=GT --data-urlencode error=0 > /dev/null
        api "${WORK}/token" POST api/qualitygates/select --data-urlencode gateName=orb-fails \
            --data-urlencode "projectKey=${project}" > /dev/null
        echo "${project}'s quality gate now fails every analysis."
        ;;
    *)
        echo "ERROR: Unknown action '${ACTION}': token or failing-gate." >&2
        exit 2
        ;;
esac
