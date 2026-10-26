#!/bin/bash

# Shared helpers for the sonarqube-orb commands. Each command passes this
# file to its step as SCRIPT_SONARQUBE_LIB, and its script evals it after
# set -euo pipefail, so it only defines functions and variables.

# sq_subst VALUE: prints VALUE with environment variables expanded. The value
# is piped in on stdin: passed as an argument, a value starting with "-"
# would be parsed as a flag. Without the CircleCI CLI (local runs and GitHub
# Actions), the value is used as is.
sq_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# sq_bool NAME VALUE: prints true or false. CircleCI passes boolean
# parameters as 1 or 0; local callers and GitHub Actions use true or false.
sq_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            exit 1
            ;;
    esac
}

# sq_match VALUE REGEX: [[ VALUE =~ REGEX ]] in the C locale, where a range
# such as [a-z] matches only ASCII letters (cimg images set LC_ALL to
# en_US.UTF-8, where it also matches letters such as é).
sq_match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

# sq_env_var_name PARAMETER VALUE: stops the step unless VALUE can name an
# environment variable.
sq_env_var_name() {
    if ! sq_match "$2" '^[A-Za-z_][A-Za-z0-9_]*$'; then
        echo "ERROR: ${1} must name an environment variable, not '${2}'." >&2
        exit 1
    fi
}

# sq_export NAME VALUE: exports NAME=VALUE, shell-quoted, to later steps
# through BASH_ENV.
sq_export() {
    if [[ -z "${BASH_ENV:-}" ]]; then
        echo "WARN: BASH_ENV is not set, so ${1} is not exported to later steps." >&2
        return 0
    fi
    printf 'export %s=%q\n' "$1" "$2" >> "${BASH_ENV}"
}

# split_shell_words STRING: splits STRING into the SHELL_WORDS array the way
# the shell splits a command line into words, but expands and executes
# nothing. Single quotes keep everything literal. Inside double quotes a
# backslash escapes only ", \, $, ` and newline, as in bash. Outside quotes a
# backslash escapes the next character, and a backslash-newline joins lines.
# A # that starts a word starts a comment, which runs to the end of the line.
# Spaces, tabs and newlines separate words, and '' is an empty word. Returns 1
# if a quote is never closed, 2 if the input ends in a backslash outside
# quotes (which escapes nothing), 3 for bash's $'...' or $"..." quoting, which
# it does not implement, 4 for a $(...) or backtick outside quotes, which it
# would not run, and 5 for a shell operator (| & ; < > ( )) outside quotes,
# such as a redirection or a <(...) process substitution.
split_shell_words() {
    local input=$1 word="" in_word=false quote="" char next i
    SHELL_WORDS=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if [[ "${quote}" == "'" ]]; then
            if [[ "${char}" == "'" ]]; then quote=""; else word+=${char}; fi
        elif [[ "${quote}" == '"' ]]; then
            if [[ "${char}" == '"' ]]; then
                quote=""
            elif [[ "${char}" == "\\" ]] && ((i + 1 < ${#input})); then
                next=${input:i+1:1}
                case "${next}" in
                    '"' | "\\" | '$' | '`') word+=${next}; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) word+=${char} ;;
                esac
            else
                word+=${char}
            fi
        else
            case "${char}" in
                ' ' | $'\t' | $'\n')
                    if [[ "${in_word}" == true ]]; then
                        SHELL_WORDS+=("${word}")
                        word=""
                        in_word=false
                    fi
                    ;;
                "'" | '"') quote=${char}; in_word=true ;;
                "#")
                    if [[ "${in_word}" == true ]]; then
                        word+=${char}
                    else
                        while ((i + 1 < ${#input})) && [[ "${input:i+1:1}" != $'\n' ]]; do
                            i=$((i + 1))
                        done
                    fi
                    ;;
                "\\")
                    ((i + 1 < ${#input})) || return 2
                    i=$((i + 1))
                    if [[ "${input:i:1}" != $'\n' ]]; then
                        word+=${input:i:1}
                        in_word=true
                    fi
                    ;;
                '$')
                    case "${input:i+1:1}" in
                        "'" | '"') return 3 ;;
                        "(") return 4 ;;
                    esac
                    word+=${char}
                    in_word=true
                    ;;
                '`') return 4 ;;
                '|' | '&' | ';' | '<' | '>' | '(' | ')') return 5 ;;
                *) word+=${char}; in_word=true ;;
            esac
        fi
    done
    [[ -z "${quote}" ]] || return 1
    if [[ "${in_word}" == true ]]; then
        SHELL_WORDS+=("${word}")
    fi
}

# sq_words PARAMETER VALUE: sets SQ_WORDS to VALUE split like shell words
# (see split_shell_words), naming PARAMETER in any error. Nothing in it is
# expanded or executed: a $(...) or backtick that reached a parameter through
# an environment variable (a branch name, a commit message) reaches the tool
# as text inside quotes, and fails the step outside them.
sq_words() {
    local status=0
    split_shell_words "$2" || status=$?
    case "${status}" in
        0) ;;
        1)
            echo "ERROR: ${1} could not be split into arguments: it has a quote that is never closed." >&2
            echo "  A literal ' or \" needs a backslash before it, or quotes of the other kind around it." >&2
            exit 1
            ;;
        2)
            echo "ERROR: ${1} could not be split into arguments: it ends in a backslash." >&2
            echo "  A literal \\ at the end needs another \\ before it." >&2
            exit 1
            ;;
        3)
            echo "ERROR: ${1} could not be split into arguments: \$'...' and \$\"...\" quoting is not supported." >&2
            echo "  Use '...' or \"...\" instead." >&2
            exit 1
            ;;
        4)
            echo "ERROR: ${1} could not be split into arguments: it has a \$(...) or backtick outside quotes." >&2
            echo "  ${1} is not run as shell code, so the command would not run. Quote it to pass it on as text." >&2
            exit 1
            ;;
        *)
            echo "ERROR: ${1} could not be split into arguments: it has one of | & ; < > ( ) outside quotes." >&2
            echo "  ${1} is not run as shell code, so pipes, redirections and <(...) would not work. Quote it to pass it on as text." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    SQ_WORDS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
}

# sq_properties_read FILE: sets SQ_PROPS, an associative array, to the
# properties FILE defines, read as java.util.Properties reads them: # and !
# start comments, a key ends at =, : or white space, a line ending in an odd
# number of backslashes continues on the next one, a backslash escapes the
# character after it, and a later definition of a key replaces an earlier
# one. \t, \n, \r and \f become a space; \uXXXX escapes are kept as written.
# Then, as the scanner does, ${env.NAME} in a value becomes the environment
# variable NAME, and ${KEY} the property KEY; a placeholder that can't be
# resolved is left as it is.
sq_properties_read() {
    local key value
    SQ_PROPS=()
    while IFS=$'\t' read -r key value; do
        SQ_PROPS["${key}"]=${value}
    done < <(awk '
        function unescape(c) {
            if (c == "t" || c == "n" || c == "r" || c == "f") { return " " }
            return c
        }
        function parse(s,   i, c, n, key, value, escaped) {
            n = length(s)
            key = ""
            escaped = 0
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (escaped) { key = key unescape(c); escaped = 0; continue }
                if (c == "\\") { escaped = 1; continue }
                if (c == "=" || c == ":" || c == " " || c == "\t" || c == "\f") { break }
                key = key c
            }
            while (i <= n && substr(s, i, 1) ~ /[ \t\f]/) { i++ }
            if (i <= n && (substr(s, i, 1) == "=" || substr(s, i, 1) == ":")) { i++ }
            while (i <= n && substr(s, i, 1) ~ /[ \t\f]/) { i++ }
            value = ""
            escaped = 0
            for (; i <= n; i++) {
                c = substr(s, i, 1)
                if (escaped) { value = value unescape(c); escaped = 0 }
                else if (c == "\\") { escaped = 1 }
                else { value = value (c == "\t" ? " " : c) }
            }
            if (key != "") { printf "%s\t%s\n", key, value }
        }
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[ \t\f]+/, "", line)
            if (!continued) {
                if (line == "" || line ~ /^[#!]/) { next }
                logical = line
            } else {
                logical = logical line
            }
            match(logical, /\\+$/)
            if (RSTART > 0 && RLENGTH % 2 == 1) {
                logical = substr(logical, 1, length(logical) - 1)
                continued = 1
                next
            }
            continued = 0
            parse(logical)
        }
        END { if (continued) { parse(logical) } }
    ' "$1")
    # Twice, so a property can name one resolved on the first round.
    for _ in 1 2; do
        for key in "${!SQ_PROPS[@]}"; do
            if [[ "${SQ_PROPS[${key}]}" == *\$\{* ]]; then
                SQ_PROPS["${key}"]=$(sq_resolve "${SQ_PROPS[${key}]}")
            fi
        done
    done
}

# sq_resolve VALUE: prints VALUE with its ${env.NAME} placeholders replaced
# by the environment variable NAME, and its ${KEY} placeholders by the
# property KEY in SQ_PROPS (when that one has none left itself). A
# placeholder that can't be resolved stays as it is.
sq_resolve() {
    local rest=$1 out="" name var count=0
    while [[ "${rest}" == *\$\{*\}* && "${count}" -lt 100 ]]; do
        count=$((count + 1))
        out+=${rest%%\$\{*}
        rest=${rest#*\$\{}
        name=${rest%%\}*}
        rest=${rest#*\}}
        if [[ "${name}" == env.* ]] && sq_match "${name#env.}" '^[A-Za-z_][A-Za-z0-9_]*$'; then
            var=${name#env.}
            if [[ -n "${!var+set}" ]]; then
                out+=${!var}
                continue
            fi
        elif [[ -n "${name}" && -n "${SQ_PROPS[${name}]+set}" && "${SQ_PROPS[${name}]}" != *\$\{* ]]; then
            out+=${SQ_PROPS[${name}]}
            continue
        fi
        out+="\${${name}}"
    done
    printf '%s\n' "${out}${rest}"
}

# sq_secret_key KEY: succeeds when the property KEY holds a credential, whose
# value is never printed.
sq_secret_key() {
    case "${1,,}" in
        sonar.login | sonar.password | *token* | *password* | *passphrase* | *secret*) return 0 ;;
    esac
    return 1
}

# sq_print_property KEY VALUE: prints KEY=VALUE for the log, indented, with
# a credential's value hidden.
sq_print_property() {
    if sq_secret_key "$1"; then
        printf '  %s=********\n' "$1"
    else
        printf '  %s=%s\n' "$1" "$2"
    fi
}

# sq_host_url HOST_URL: sets SQ_HOST_URL to the server the analysis goes
# to, the way the scanner picks it: the host_url parameter, else
# SONAR_HOST_URL, else sonar.host.url in SQ_PROPS. SQ_HOST_FROM says which.
# An empty SQ_HOST_URL means none is set, and the scanner then uses
# SonarQube Cloud.
sq_host_url() {
    SQ_HOST_URL=$(sq_subst "$1")
    SQ_HOST_FROM="host_url"
    if [[ -z "${SQ_HOST_URL}" && -n "${SONAR_HOST_URL:-}" ]]; then
        SQ_HOST_URL=${SONAR_HOST_URL}
        SQ_HOST_FROM="SONAR_HOST_URL"
    fi
    if [[ -z "${SQ_HOST_URL}" && -n "${SQ_PROPS[sonar.host.url]+set}" ]]; then
        SQ_HOST_URL=${SQ_PROPS[sonar.host.url]}
        SQ_HOST_FROM="sonar.host.url"
        if [[ "${SQ_HOST_URL}" == *\$\{* ]]; then
            echo "WARN: sonar.host.url holds a placeholder this step can't resolve (${SQ_HOST_URL}), so it doesn't know the server." >&2
            SQ_HOST_URL=""
        fi
    fi
    if [[ -z "${SQ_HOST_URL}" ]]; then
        SQ_HOST_FROM=""
        return 0
    fi
    while [[ "${SQ_HOST_URL}" == */ ]]; do
        SQ_HOST_URL=${SQ_HOST_URL%/}
    done
    if sq_match "${SQ_HOST_URL}" '^https?://[^/?#]*@'; then
        echo "ERROR: The server URL (${SQ_HOST_FROM}) must not hold credentials (user:password@ before the host). Use a token instead." >&2
        exit 1
    fi
    if ! sq_match "${SQ_HOST_URL}" '^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]?#]*)?$' \
        && ! sq_match "${SQ_HOST_URL}" '^https?://\[[0-9A-Fa-f:.]+\](:[0-9]+)?(/[^[:space:]?#]*)?$'; then
        echo "ERROR: The server URL (${SQ_HOST_FROM}) must be an http:// or https:// URL without a query, not '${SQ_HOST_URL}'." >&2
        exit 1
    fi
}

# sq_cloud URL: succeeds when URL is SonarQube Cloud, in any region.
sq_cloud() {
    sq_match "${1,,}" '^https://([a-z0-9-]+\.)?(sonarcloud\.io|sonarqube\.us)(/|$)'
}

# sq_loopback URL: succeeds when URL's host is this machine.
sq_loopback() {
    sq_match "${1,,}" '^https?://(localhost|127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\])(:[0-9]+)?(/|$)'
}

# shellcheck disable=SC2034 # read by the script that evals this file
# sq_token NAME: sets SQ_TOKEN to the value of the environment variable NAME
# names (the token parameter), which may be empty.
sq_token() {
    sq_env_var_name token "$1"
    # The token is read into a variable, which xtrace would print.
    set +o xtrace
    SQ_TOKEN_VAR=$1
    SQ_TOKEN=${!1:-}
}

# sq_curl_init: sets SQ_CURL to the curl command the API calls share. It
# fails on an HTTP error (keeping the error's body when curl can), and
# retries transient failures.
sq_curl_init() {
    local help
    if ! command -v curl > /dev/null 2>&1; then
        echo "ERROR: curl is not on the PATH. Install it in an earlier step." >&2
        exit 1
    fi
    SQ_CURL=(curl -sS --retry 3 --connect-timeout 30 --max-time 300)
    # The output is captured, not piped, so curl can't hit a closed pipe.
    help=$({ curl --help all || curl --help; } 2>&1) || true
    if [[ "${help}" == *--fail-with-body* ]]; then
        SQ_CURL+=(--fail-with-body)
    else
        SQ_CURL+=(--fail)
    fi
}

# sq_auth_header FILE NAME VALUE: writes the HTTP header "NAME: VALUE" to
# FILE, which curl reads with -H @FILE, so a token never appears on a
# command line. FILE is created private.
sq_auth_header() {
    (umask 077 && printf '%s: %s\n' "$2" "$3" > "$1")
}

# sq_api URL OUT [CURL_ARG...]: calls the SonarQube Web API at URL with the
# token in SQ_AUTH_FILE (when set), writes the body to OUT and prints the
# HTTP status. A call with the token only goes over https, or to this
# machine. Returns 1 when curl could not get an answer at all.
sq_api() {
    local url=$1 out=$2 code rc=0 proto="=https"
    local -a auth=() extra=()
    shift 2
    # Bash 4.0 calls an empty "$@" unbound under set -u.
    if [[ $# -gt 0 ]]; then
        extra=("$@")
    fi
    if sq_loopback "${url}" || [[ -z "${SQ_AUTH_FILE:-}" ]]; then
        proto="=http,https"
    fi
    if [[ -n "${SQ_AUTH_FILE:-}" ]]; then
        auth=(-H "@${SQ_AUTH_FILE}")
    fi
    code=$("${SQ_CURL[@]}" --proto "${proto}" --proto-redir "${proto}" ${auth[@]+"${auth[@]}"} \
        -o "${out}" -w '%{http_code}' ${extra[@]+"${extra[@]}"} "${url}" 2> "${out}.err") || rc=$?
    # curl exits 22 for an HTTP error, which the status says.
    if [[ "${rc}" -ne 0 && "${rc}" -ne 22 ]]; then
        echo "WARN: Could not reach ${url%%\?*}: $(head -c 300 "${out}.err")" >&2
        return 1
    fi
    printf '%s\n' "${code}"
}

# shellcheck disable=SC2034 # read by the script that evals this file
# sq_ci_context: reads the build's CI service, commit, branch and pull
# request from CircleCI's or GitHub Actions' environment, into SQ_CI
# (CircleCI, GitHub Actions or empty), SQ_CI_SHA, SQ_CI_REPOSITORY
# (owner/name), SQ_CI_BRANCH, SQ_CI_TAG, and for a pull request SQ_CI_PR_KEY,
# SQ_CI_PR_BRANCH, SQ_CI_PR_BASE and SQ_CI_PR_HEAD_SHA (empty when the
# service doesn't say).
sq_ci_context() {
    local number
    SQ_CI="" SQ_CI_SHA="" SQ_CI_REPOSITORY="" SQ_CI_BRANCH="" SQ_CI_TAG=""
    SQ_CI_PR_KEY="" SQ_CI_PR_BRANCH="" SQ_CI_PR_BASE="" SQ_CI_PR_HEAD_SHA=""
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        SQ_CI="GitHub Actions"
        SQ_CI_SHA=${GITHUB_SHA:-}
        SQ_CI_REPOSITORY=${GITHUB_REPOSITORY:-}
        case "${GITHUB_EVENT_NAME:-}" in
            pull_request | pull_request_target | pull_request_review | pull_request_review_comment)
                number=""
                if [[ "${GITHUB_REF:-}" =~ ^refs/pull/([0-9]+)/ ]]; then
                    number=${BASH_REMATCH[1]}
                elif [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]] && command -v jq > /dev/null 2>&1; then
                    number=$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH}" 2> /dev/null || true)
                fi
                SQ_CI_PR_KEY=${number}
                SQ_CI_PR_BRANCH=${GITHUB_HEAD_REF:-}
                SQ_CI_PR_BASE=${GITHUB_BASE_REF:-}
                if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]] && command -v jq > /dev/null 2>&1; then
                    SQ_CI_PR_HEAD_SHA=$(jq -r '.pull_request.head.sha // empty' "${GITHUB_EVENT_PATH}" 2> /dev/null || true)
                fi
                ;;
            *)
                if [[ "${GITHUB_REF_TYPE:-}" == "tag" || "${GITHUB_REF:-}" == refs/tags/* ]]; then
                    SQ_CI_TAG=${GITHUB_REF_NAME:-${GITHUB_REF#refs/tags/}}
                elif [[ "${GITHUB_REF:-}" == refs/heads/* ]]; then
                    SQ_CI_BRANCH=${GITHUB_REF#refs/heads/}
                fi
                ;;
        esac
    elif [[ "${CIRCLECI:-}" == "true" ]]; then
        SQ_CI="CircleCI"
        SQ_CI_SHA=${CIRCLE_SHA1:-}
        if [[ -n "${CIRCLE_PROJECT_USERNAME:-}" && -n "${CIRCLE_PROJECT_REPONAME:-}" ]]; then
            SQ_CI_REPOSITORY="${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
        fi
        SQ_CI_TAG=${CIRCLE_TAG:-}
        # CircleCI sets CIRCLE_PULL_REQUEST, the pull request's URL, when the
        # branch has an open pull request, and CIRCLE_PR_NUMBER for one from
        # a fork. It doesn't say which branch the pull request goes into.
        number=${CIRCLE_PR_NUMBER:-}
        if [[ -z "${number}" && "${CIRCLE_PULL_REQUEST:-}" =~ /([0-9]+)/?$ ]]; then
            number=${BASH_REMATCH[1]}
        fi
        if [[ -n "${number}" ]]; then
            SQ_CI_PR_KEY=${number}
            SQ_CI_PR_BRANCH=${CIRCLE_BRANCH:-}
        elif [[ -z "${SQ_CI_TAG}" ]]; then
            SQ_CI_BRANCH=${CIRCLE_BRANCH:-}
        fi
    fi
}
