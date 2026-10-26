#!/bin/bash
#
# Prints checksum table entries for a SonarScanner CLI release, ready to
# paste into the sha512sums table in install.sh. A development helper: the
# orb never runs it.
#
#   src/scripts/install_hash.sh -v <version> [-a "<arch> ..."] [-c <checksum>]
#
#   -a  architectures to hash (default: every one install.sh supports)
#   -c  a checksum for the asset from another official source, as
#       SHA-256:<hex> or SHA1:<hex>, for a release whose published checksums
#       don't cover it (verify_upstream finds nothing); or NONE to add an
#       entry that is not anchored to any published checksum. -c never
#       overrides a failure to fetch or verify what SonarSource did publish:
#       re-run once the source is reachable.
#
# The version is the release's version without its build number (8.2.0 for
# 8.2.0.6438). Add the build number to sq_scanner_builds in install.sh first,
# or give it as SQ_SCANNER_BUILD=6438 in the environment.
#
# Each asset is checked against what SonarSource published for the release
# before its entry is printed (see verify_upstream). Entries go to stdout and
# everything else to stderr, so the output can be pasted as is.

set -euo pipefail

# >>> upstream verification >>>
# SonarSource's OpenPGP key, by primary key fingerprint. SonarSource signs
# releases with a subkey of it that it replaces every year or so, so the
# public key is fetched from keyservers that keep every subkey, and a
# signature counts only when gpg ties it to this primary key.
SONARSOURCE_KEY=679F1EE92B19609DE816FDE81DB198F93525EC1A

# verify_upstream VERSION ARCH ASSET: checks ASSET against three things
# SonarSource published for it: the SHA-256 beside it on its download site,
# the SHA-256 Maven Central lists for the same file (Maven Central never
# replaces a published file, so it is a record independent of the download
# site), and its OpenPGP signature. Both checksums must match and the
# signature must verify with SONARSOURCE_KEY. A signature from a subkey
# SonarSource has since revoked is reported, and the entry then rests on the
# two checksums: SonarSource revoked the subkey that signed 7.0.0 to 8.0.0 as
# compromised. Returns 0 when it all matches, 2 when nothing was published,
# and 1 otherwise. Needs gpg.
verify_upstream() {
    local name=${3##*/} full actual published source url rc found=0 status signer revoked
    full=${name#sonar-scanner-cli-}
    full=${full%-linux-*}
    actual=$(sha256sum "$3" | awk '{ print $1 }')
    for source in "SonarSource's download site|https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/${name}.sha256" \
        "Maven Central|https://repo1.maven.org/maven2/org/sonarsource/scanner/cli/sonar-scanner-cli/${full}/${name}.sha256"; do
        url=${source#*|}
        rc=0
        hash_fetch "${url}" published.sha256 || rc=$?
        if [[ "${rc}" -eq 1 ]]; then
            return 1
        elif [[ "${rc}" -eq 2 ]]; then
            echo "ERROR: ${source%%|*} publishes no SHA-256 for ${name} (${url})."
            continue
        fi
        found=$((found + 1))
        published=$(awk 'NR == 1 { print $1 }' published.sha256)
        if [[ "${actual}" != "${published}" ]]; then
            echo "ERROR: ${name} has SHA-256 ${actual}, but ${source%%|*} publishes ${published:-nothing readable}."
            return 1
        fi
        echo "ok: ${name} matches the SHA-256 ${source%%|*} publishes."
    done
    rc=0
    hash_fetch "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/${name}.asc" "${name}.asc" || rc=$?
    if [[ "${rc}" -eq 1 ]]; then
        return 1
    elif [[ "${rc}" -eq 2 && "${found}" -eq 0 ]]; then
        echo "SonarSource publishes no checksum or signature for ${name}."
        return 2
    elif [[ "${rc}" -eq 2 || "${found}" -lt 2 ]]; then
        echo "ERROR: ${name} needs both published SHA-256 sums and its signature (${name}.asc)."
        return 1
    fi
    if ! command -v gpg > /dev/null; then
        echo "ERROR: gpg is required to verify the signature on ${name}."
        return 1
    fi
    mkdir -m 700 gnupg
    for url in "https://keys.openpgp.org/vks/v1/by-fingerprint/${SONARSOURCE_KEY}" \
        "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${SONARSOURCE_KEY}"; do
        rc=0
        hash_fetch "${url}" key.asc || rc=$?
        if [[ "${rc}" -eq 0 ]]; then
            gpg --homedir gnupg --batch --no-autostart --quiet --import key.asc > /dev/null 2>&1 || true
        fi
    done
    status=$(gpg --homedir gnupg --batch --no-autostart --status-fd 1 --verify "${name}.asc" "$3" 2> gpg.log) || true
    signer=$(awk '$2 == "VALIDSIG" { print $NF }' <<< "${status}")
    if [[ "${signer}" != "${SONARSOURCE_KEY}" ]]; then
        echo "ERROR: the signature on ${name} does not verify with SonarSource's key ${SONARSOURCE_KEY}${signer:+ (it names ${signer})}."
        sed 's/^/  /' gpg.log
        return 1
    fi
    revoked=$(awk '$2 == "KEYREVOKED" || $2 == "REVKEYSIG" { print "yes"; exit }' <<< "${status}")
    if [[ -n "${revoked}" ]]; then
        echo "WARN: ${name} is signed with $(awk '$2 == "VALIDSIG" { print $3 }' <<< "${status}") by a subkey SonarSource has revoked" \
            "($(sed -n 's/^gpg: reason for revocation: //p' gpg.log | head -n 1)). Its entry rests on the two published SHA-256 sums."
    else
        echo "ok: the signature on ${name} verified (SonarSource key ${SONARSOURCE_KEY})."
    fi
}
# <<< upstream verification <<<

# >>> shared install_hash logic >>>
# Everything from here to the end marker is identical in the install_hash.sh
# of every juburr orb. The tool definition, and with it the asset names and
# URLs, is read from install.sh so the two scripts cannot disagree.

hash_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

hash_usage() {
    printf 'Usage: %s -v <version> [-a "<arch> ..."] [-c SHA-256:<hex> | -c SHA1:<hex> | -c NONE]\n' "$0" >&2
    exit 1
}

# hash_fetch URL DEST [CURL_ARG...]: downloads URL to DEST for verify_upstream.
# Returns 0 on success, 2 when the server says there is no such file (404),
# and 1 on any other failure, which must never be read as "not published".
hash_fetch() {
    local url=$1 dest=$2 code rc=0
    shift 2
    # Without -f, curl exits 0 on an HTTP error, so a non-zero exit is a
    # transfer failure, such as a connection that closed partway.
    code=$(curl -sSL --proto '=https' --proto-redir '=https' --retry 5 --connect-timeout 30 \
        -o "${dest}" -w '%{http_code}' "$@" "${url}") || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        echo "ERROR: could not download ${url} (curl exit code ${rc})."
        return 1
    fi
    case "${code}" in
        200) return 0 ;;
        404) return 2 ;;
        *)
            echo "ERROR: could not download ${url} (HTTP status ${code:-none})."
            return 1
            ;;
    esac
}

# hash_version_le A B: succeeds if version A sorts at or before version B.
hash_version_le() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

# Loads install.sh's tool definition and shared functions, without its
# checksum table or main call.
INSTALL_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"
# shellcheck source=/dev/null
source <(sed -n '/^# >>> tool definition >>>$/,/^# <<< shared install logic <<<$/p' "${INSTALL_SCRIPT}")
if ! declare -F tool_asset_name > /dev/null; then
    hash_die "Could not load the tool definition from ${INSTALL_SCRIPT}."
fi

VERSION=""
ARCHES=""
UPSTREAM_CHECKSUM=""
while getopts ':v:a:c:' flag; do
    case "${flag}" in
        v) VERSION=${OPTARG} ;;
        a) ARCHES=${OPTARG} ;;
        c) UPSTREAM_CHECKSUM=${OPTARG} ;;
        *) hash_usage ;;
    esac
done
VERSION=${VERSION#v}
if [[ -z "${VERSION}" ]]; then
    hash_usage
fi
if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    hash_die "Invalid version '${VERSION}'."
fi
ARCHES=${ARCHES:-${TOOL_ARCHES}}
read -r -a ARCH_LIST <<< "${ARCHES}"
if [[ "${#ARCH_LIST[@]}" -eq 0 ]]; then
    hash_die "-a names no architecture. Supported: ${TOOL_ARCHES}."
fi
for arch in "${ARCH_LIST[@]}"; do
    if [[ " ${TOOL_ARCHES} " != *" ${arch} "* ]]; then
        hash_die "Unsupported architecture '${arch}'. Supported: ${TOOL_ARCHES}."
    fi
done
if [[ -n "${UPSTREAM_CHECKSUM}" && "${UPSTREAM_CHECKSUM}" != "NONE" ]]; then
    if [[ ! "${UPSTREAM_CHECKSUM}" =~ ^(SHA-256:[0-9a-f]{64}|SHA1:[0-9a-f]{40})$ ]]; then
        hash_die "-c must be SHA-256:<hex>, SHA1:<hex>, or NONE."
    fi
    if [[ "${#ARCH_LIST[@]}" -gt 1 ]]; then
        hash_die "-c describes one asset, so pick its architecture with -a."
    fi
fi
REQUIRED_TOOLS=(curl sha256sum sha512sum tar gzip)
if [[ "${UPSTREAM_CHECKSUM}" == SHA1:* ]]; then
    REQUIRED_TOOLS+=(sha1sum)
fi
for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "${tool}" > /dev/null || hash_die "${tool} is required."
done

HASH_WORK_DIR=$(mktemp -d)
trap 'rm -rf "${HASH_WORK_DIR}"' EXIT

# check_upstream VERSION ARCH ASSET: anchors ASSET to what the project
# published, via verify_upstream (which returns 2 when nothing was published)
# and any checksum supplied with -c.
check_upstream() {
    local rc=0 expected actual
    (cd "${3%/*}" && verify_upstream "$1" "$2" "$3") >&2 || rc=$?
    if [[ "${rc}" -ne 0 && "${rc}" -ne 2 ]]; then
        hash_die "${3##*/} could not be verified against what ${TOOL_NAME} published for ${1}."
    fi
    # NONE only stands in for a checksum that was never published.
    if [[ "${UPSTREAM_CHECKSUM}" == "NONE" ]]; then
        if [[ "${rc}" -eq 2 ]]; then
            printf 'WARN: -c NONE: %s is not checked against any published checksum.\n' "${3##*/}" >&2
        fi
        return 0
    fi
    if [[ -n "${UPSTREAM_CHECKSUM}" ]]; then
        expected=${UPSTREAM_CHECKSUM#*:}
        case "${UPSTREAM_CHECKSUM%%:*}" in
            SHA-256) actual=$(sha256sum "$3" | awk '{ print $1 }') ;;
            SHA1) actual=$(sha1sum "$3" | awk '{ print $1 }') ;;
        esac
        if [[ "${actual}" != "${expected}" ]]; then
            hash_die "${3##*/} does not match the checksum given with -c (${actual})."
        fi
        printf 'ok: %s matches the checksum given with -c.\n' "${3##*/}" >&2
    elif [[ "${rc}" -eq 2 ]]; then
        hash_die "${TOOL_NAME} published no checksum for ${3##*/}. Supply one from another official source with -c," \
            "or pass -c NONE to add the entry unanchored."
    fi
}

ENTRIES=()
for arch in "${ARCH_LIST[@]}"; do
    # orb_extract works in ORB_WORK_DIR and names ORB_ASSET_NAME in messages.
    ORB_WORK_DIR="${HASH_WORK_DIR}/${arch}"
    ORB_ASSET_NAME=$(tool_asset_name "${VERSION}" "${arch}")
    member=$(tool_archive_member "${VERSION}" "${arch}")
    mkdir -p "${ORB_WORK_DIR}"
    mapfile -t urls < <(tool_asset_urls "${VERSION}" "${arch}" "${ORB_ASSET_NAME}")
    if ! orb_download "${ORB_WORK_DIR}/${ORB_ASSET_NAME}" "${urls[@]}" >&2; then
        hash_die "Could not download ${ORB_ASSET_NAME}. If ${TOOL_NAME} ${VERSION} has no ${arch} build," \
            "leave ${arch} out with -a."
    fi
    check_upstream "${VERSION}" "${arch}" "${ORB_WORK_DIR}/${ORB_ASSET_NAME}"
    # Hashes the same file install.sh verifies, with the same checks on it.
    if ! orb_extract "${ORB_WORK_DIR}/${ORB_ASSET_NAME}" "${member}" >&2; then
        hash_die "Could not take ${member} from ${ORB_ASSET_NAME}."
    fi
    ENTRIES+=("$(printf '    ["%s/%s"]="%s"' "${VERSION}" "${arch}" "$(sha512sum "${ORB_VERIFIED_FILE}" | awk '{ print $1 }')")")
done
# Nothing is printed until every architecture has passed.
printf '%s\n' "${ENTRIES[@]}"
# <<< shared install_hash logic <<<
