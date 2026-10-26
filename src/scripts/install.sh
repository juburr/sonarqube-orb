#!/bin/bash
#
# Installs the SonarScanner CLI for the install command: the release archive
# for Linux with its own Java runtime, unpacked into a directory of its own,
# verified against the checksum table in this file before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (SonarScanner
#      CLI only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# Add the checksums for a new release with:
#   src/scripts/install_hash.sh -v <version>
# after adding its build number to sq_scanner_builds below.

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing the SonarScanner CLI needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="sonarqube-orb"
TOOL_NAME="SonarScanner CLI"
TOOL_BINARY="sonar-scanner"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME. It is the scanner's own directory,
# whose bin directory goes on the PATH.
TOOL_DEFAULT_INSTALL_DIR=".sonarqube-orb/sonar-scanner"

# SonarSource numbers each release with a build number after its version, as
# in 8.2.0.6438. The version parameter and the checksum table use the version
# alone, and this list supplies the build number the download URL needs.
declare -A sq_scanner_builds=(
    ["8.2.0"]="6438"
    ["8.1.0"]="6389"
    ["8.0.1"]="6346"
    ["8.0.0"]="6341"
    ["7.3.0"]="5189"
    ["7.2.0"]="5079"
    ["7.1.0"]="4889"
    ["7.0.2"]="4839"
    ["7.0.1"]="4817"
    ["7.0.0"]="4796"
)

# A full version, such as 8.2.0.6438, is accepted too: it is split here,
# before the shared install logic checks the version, so a release this orb
# doesn't list yet can be installed with verify_checksums: known_versions.
# SQ_SCANNER_BUILD, when set, gives the build number the same way (for
# install_hash.sh -v, before the release is added to the list above).
SQ_SCANNER_BUILD=${SQ_SCANNER_BUILD:-}
if [[ -n "${PARAM_VERSION:-}" ]]; then
    # Expanded as the shared install logic expands it, value on stdin.
    if command -v circleci > /dev/null 2>&1; then
        PARAM_VERSION=$(printf '%s' "${PARAM_VERSION}" | circleci env subst)
    fi
    if [[ "${PARAM_VERSION}" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)$ ]]; then
        PARAM_VERSION=${BASH_REMATCH[1]}
        SQ_SCANNER_BUILD=${BASH_REMATCH[2]}
    fi
fi

# sq_scanner_build VERSION: the build number of SonarScanner CLI VERSION.
sq_scanner_build() {
    local listed=${sq_scanner_builds[$1]:-}
    if [[ -n "${SQ_SCANNER_BUILD}" ]]; then
        if [[ ! "${SQ_SCANNER_BUILD}" =~ ^[0-9]+$ ]]; then
            orb_die "SQ_SCANNER_BUILD must be a build number, such as 6438, not '${SQ_SCANNER_BUILD}'."
        fi
        if [[ -n "${listed}" && "${listed}" != "${SQ_SCANNER_BUILD}" ]]; then
            orb_die "SonarScanner CLI $1 is build ${listed}, not ${SQ_SCANNER_BUILD}."
        fi
        printf '%s\n' "${SQ_SCANNER_BUILD}"
    elif [[ -n "${listed}" ]]; then
        printf '%s\n' "${listed}"
    else
        orb_die "This orb doesn't know the build number of SonarScanner CLI $1, which its download URL needs." \
            "Give the full version SonarSource publishes, such as $1.1234."
    fi
}

# sq_platform ARCH: the platform name SonarSource gives ARCH.
sq_platform() {
    case "$1" in
        amd64) printf 'x64\n' ;;
        arm64) printf 'aarch64\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# tool_asset_name VERSION ARCH: the release asset to download, the Linux
# package with its own Java runtime.
tool_asset_name() {
    local build
    build=$(sq_scanner_build "$1")
    printf 'sonar-scanner-cli-%s.%s-linux-%s.zip\n' "$1" "${build}" "$(sq_platform "$2")"
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order: SonarSource's download site, then Maven Central, which
# publishes the same files. A download_base_url mirror is tried in both
# layouts, so it can mirror either one, such as an Artifactory or Nexus
# remote repository of Maven Central.
tool_asset_urls() {
    local full
    full="$1.$(sq_scanner_build "$1")"
    if [[ -n "${SQ_DOWNLOAD_BASE_URL:-}" ]]; then
        printf '%s/Distribution/sonar-scanner-cli/%s\n' "${SQ_DOWNLOAD_BASE_URL}" "$3"
        printf '%s/org/sonarsource/scanner/cli/sonar-scanner-cli/%s/%s\n' "${SQ_DOWNLOAD_BASE_URL}" "${full}" "$3"
    else
        printf 'https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/%s\n' "$3"
        printf 'https://repo1.maven.org/maven2/org/sonarsource/scanner/cli/sonar-scanner-cli/%s/%s\n' "${full}" "$3"
    fi
}

# tool_archive_member VERSION ARCH: empty, since the scanner installs as a
# whole directory. The checksum table holds the SHA-512 of the release
# archive.
tool_archive_member() {
    :
}

# tool_version BINARY: prints the scanner's version, and the Java runtime
# it runs on, without contacting a server.
tool_version() {
    "$1" --version
}

# sq_download_base_url: sets SQ_DOWNLOAD_BASE_URL from the download_base_url
# parameter, an internal mirror such as Artifactory, Nexus or S3. The
# checksum table, not the mirror, decides what is installed.
sq_download_base_url() {
    local authority
    SQ_DOWNLOAD_BASE_URL=$(orb_subst "${PARAM_DOWNLOAD_BASE_URL:-}")
    SQ_DOWNLOAD_BASE_URL=${SQ_DOWNLOAD_BASE_URL%/}
    if [[ -z "${SQ_DOWNLOAD_BASE_URL}" ]]; then
        return 0
    fi
    # Credentials in the URL would show in the log and on curl's command
    # line, so they are refused before the URL is printed anywhere.
    authority=${SQ_DOWNLOAD_BASE_URL#*://}
    if [[ "${authority%%/*}" == *@* ]]; then
        orb_die "download_base_url must not hold credentials (user:password@ before the host): they would show in the log and on curl's command line."
    fi
    # Nor can a query or fragment, which can hold a token too, and would end
    # up in the middle of every download URL.
    if [[ "${SQ_DOWNLOAD_BASE_URL}" == *[?#]* ]]; then
        orb_die "download_base_url must not have a query or fragment (? or #): it could hold a token, which would show in the log."
    fi
    if [[ ! "${SQ_DOWNLOAD_BASE_URL}" =~ ^https://[^[:space:]\"\'\<\>\\]+$ ]]; then
        orb_die "download_base_url must be an https:// URL, not '${SQ_DOWNLOAD_BASE_URL}'."
    fi
    orb_info "  download mirror:  ${SQ_DOWNLOAD_BASE_URL} (in place of https://binaries.sonarsource.com and Maven Central)"
}

# The file each installation holds, naming what was installed.
SQ_MARKER=".sonarqube-orb"

# sq_scanner_tree DIR: whether DIR is a SonarScanner CLI installation this
# script may replace: one an earlier install wrote its marker into.
sq_scanner_tree() {
    [[ -f "$1/${SQ_MARKER}" && -f "$1/bin/sonar-scanner" ]]
}

# sq_unzip ZIP DIR: unpacks ZIP into DIR with unzip, or bsdtar, which reads
# zip archives too. Both keep the files' modes and symbolic links.
sq_unzip() {
    if command -v unzip > /dev/null 2>&1; then
        unzip -q "$1" -d "$2"
    else
        bsdtar -x -f "$1" -C "$2"
    fi
}

# The scanner is a Java application with its own Java runtime, released as a
# zip archive that unpacks into one directory. That directory is
# install_path, and its bin directory goes on the PATH, so this replaces the
# shared single-binary install. An earlier installation is only replaced
# once the new one has run.
tool_install() {
    local dir=${ORB_INSTALL_PATH%/*} name=${ORB_INSTALL_PATH##*/} staging="" full top
    sq_download_base_url
    ORB_BIN_DIR="${ORB_INSTALL_PATH}/bin"
    if [[ -L "${ORB_INSTALL_PATH}" ]]; then
        orb_die "install_path ${ORB_INSTALL_PATH} is a symbolic link. Point install_path at the directory itself."
    fi
    if [[ -e "${ORB_INSTALL_PATH}" && ! -d "${ORB_INSTALL_PATH}" ]]; then
        orb_die "install_path ${ORB_INSTALL_PATH} exists and is not a directory."
    fi
    # Empty directories hold nothing to lose, such as a bin directory put on
    # the PATH before the install.
    if [[ -d "${ORB_INSTALL_PATH}" ]] && ! sq_scanner_tree "${ORB_INSTALL_PATH}" \
        && [[ -n "$(find "${ORB_INSTALL_PATH}" -mindepth 1 ! -type d -print -quit 2>&1)" ]]; then
        orb_die "install_path ${ORB_INSTALL_PATH} holds something other than a SonarScanner CLI installation, which this install would replace." \
            "Choose a new or empty directory, or one an earlier install installed into."
    fi
    if ! command -v unzip > /dev/null 2>&1 && ! command -v bsdtar > /dev/null 2>&1; then
        orb_die "Installing the SonarScanner CLI needs unzip (or bsdtar), which is not available. Install it in an earlier" \
            "step, for example with 'sudo apt-get install -y unzip', or 'microdnf install -y unzip' on Red Hat UBI images."
    fi
    orb_fetch_verified

    dir=${dir:-/}
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if staging=$(mktemp -d "${dir%/}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    else
        orb_die "Could not install the SonarScanner CLI to ${ORB_INSTALL_PATH}. Choose an install_path this job's user can write to without root."
    fi
    mkdir "${staging}/unpack"
    if ! sq_unzip "${ORB_VERIFIED_FILE}" "${staging}/unpack" > "${ORB_WORK_DIR}/unzip.log" 2>&1; then
        orb_die "Could not unpack ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/unzip.log")"
    fi
    # The archive holds one directory, sonar-scanner-<version>-linux-<platform>,
    # with the launcher, the scanner's jar and the Java runtime.
    full="${ORB_VERSION}.$(sq_scanner_build "${ORB_VERSION}")"
    top="${staging}/unpack/sonar-scanner-${full}-linux-$(sq_platform "${ORB_ARCH}")"
    if [[ "$(find "${staging}/unpack" -mindepth 1 -maxdepth 1 | wc -l)" -ne 1 || -L "${top}" || ! -d "${top}" ]] \
        || [[ ! -f "${top}/bin/sonar-scanner" || ! -f "${top}/lib/sonar-scanner-cli-${full}.jar" || ! -f "${top}/jre/bin/java" ]]; then
        orb_die "${ORB_ASSET_NAME} does not hold a SonarScanner CLI ${full} installation" \
            "(sonar-scanner-${full}-linux-$(sq_platform "${ORB_ARCH}")/ with bin/sonar-scanner, its jar and a Java runtime)."
    fi
    {
        printf 'version=%s\n' "${full}"
        printf 'arch=%s\n' "${ORB_ARCH}"
        printf 'asset=%s\n' "${ORB_ASSET_NAME}"
        printf 'sha512=%s\n' "${ORB_EXPECTED_SHA512}"
        printf 'verify_checksums=%s\n' "${ORB_VERIFY_CHECKSUMS}"
    } > "${top}/${SQ_MARKER}"
    mv "${top}" "${staging}/scanner"
    orb_smoke_test "${staging}/scanner/bin/sonar-scanner"
    # The earlier installation moves into the staging directory, which the
    # EXIT trap removes, and comes back if the new one can't take its place.
    if [[ -d "${ORB_INSTALL_PATH}" ]] && ! mv "${ORB_INSTALL_PATH}" "${staging}/previous"; then
        orb_die "Could not replace ${ORB_INSTALL_PATH}. Choose an install_path this job's user can write to without root."
    fi
    if ! mv "${staging}/scanner" "${ORB_INSTALL_PATH}"; then
        if [[ -d "${staging}/previous" ]]; then
            mv "${staging}/previous" "${ORB_INSTALL_PATH}" || true
        fi
        orb_die "Could not install the SonarScanner CLI to ${ORB_INSTALL_PATH}. Choose an install_path this job's user can write to without root."
    fi
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    # The directory may be added to the PATH, where ":" separates entries.
    if [[ "${value}" == *:* ]]; then
        orb_die "${1} can't contain ':', which separates PATH entries: '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty. An empty file is refused, which matters when there
# is no checksum to catch it.
orb_extract() {
    local asset=$1 member=$2 dir
    ORB_VERIFIED_FILE=${asset}
    if [[ -n "${member}" ]]; then
        dir="${ORB_WORK_DIR}/extract"
        rm -rf "${dir}"
        mkdir "${dir}"
        # -o (don't restore the archive's owner) is spelled the same in GNU
        # tar, bsdtar and BusyBox tar, even one built without long options.
        if ! tar -xzf "${asset}" -o -C "${dir}" -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
            orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
            return 1
        fi
        ORB_VERIFIED_FILE="${dir}/${member}"
        if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
            orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
            return 1
        fi
    fi
    if [[ ! -s "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${ORB_VERIFIED_FILE##*/} is empty."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            if ! cp "${ORB_CACHE_FILE}" "${asset}"; then
                orb_warn "Could not read the cached ${ORB_ASSET_NAME}. Downloading it instead."
                use_cache=false
                continue
            fi
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
                "Set caching to false to skip it until then."
            # Like saving it, removing it is best-effort: a read-only cache
            # directory only means the download isn't cached.
            rm -f "${ORB_CACHE_FILE}" 2> /dev/null || true
            use_cache=false
            continue
        fi
        orb_die "The ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) download was rejected and not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST. The
# file is staged under DEST's name in a private directory beside DEST and run
# once (orb_smoke_test) before a single rename replaces DEST, so a binary
# that can't run here leaves an existing install in place.
orb_install_file() {
    local dir=${2%/*} name=${2##*/} staging=""
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if staging=$(mktemp -d "${dir}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    fi
    if [[ -z "${staging}" ]] || ! { cp "$1" "${staging}/${name}" && chmod 0755 "${staging}/${name}"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
    orb_smoke_test "${staging}/${name}"
    if ! mv -f "${staging}/${name}" "$2"; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# orb_smoke_test FILE: runs the new binary once, which catches a build that
# can't run here: one for another architecture (exit code 126), or one that
# crashes, such as with SIGILL on a CPU it doesn't support. tool_version
# needs no network, so any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "$1" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The downloaded ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64 or arm64. Each covers the release archive, the zip file
# tool_asset_name names.
declare -A sha512sums=(
    ["8.2.0/amd64"]="27cd0024582febfbc67616954c7dcffc84d41cfe95e55e1b5570d89a7655b88938fec14cc66ffebf4ce90e92f995a36be463c3fd63aac180892ccfe7eeaa3288"
    ["8.2.0/arm64"]="da61b8b8c957404f3bee2c509b3da096a82e4a968864060787fe4118401a007dfaf43a326256a91f3932a48b1dddf682ccace60bec67d02d25c277bbdc736607"
    ["8.1.0/amd64"]="4a28a4762a866b1f4455a79d8ff3cac41f88b18e3652d78fe672452619125985ebe0e6203b50c36f5817d635ded84e70a466ee9e4bf0827a2a9917e3d1c068a0"
    ["8.1.0/arm64"]="b470990a94b816d4693af6821f19b3aa277d79f53961a2bcbfb870a11fb550ce88d9478d702b2a2b2cbdbb2b32fa6e10ad124ea7be70a693c208ee3bbb35157b"
    ["8.0.1/amd64"]="0f9ea6231c0373834cf2b9f0935ae34314f83026687ebee4f6f6fa0843512f0754e101b21ef2ca5b839b1b2f08e2a5c758c9575e4ae5247a934b56e37931bd29"
    ["8.0.1/arm64"]="25ffbd65db0f89dee213c77d01538646ecce883db459ea4513764164241fa6c2abbf74f97a0fa3f87b540dbbd4444d882959420769ea91bab8baadee6bf2ac43"
    ["8.0.0/amd64"]="6ed77026d027d797e08629d4e97f0b5bc0824177cd54b6132aaa52f655caa7ff768bb5bc2ea404c445affd4263dccb32e9be70c599deee9a0684d4266e2892b2"
    ["8.0.0/arm64"]="8537e587b26a2c686999e04d3d96871cf27c05d5f18f9975049b9b69c7558d3bef4b57fd90106fae1a63d452642d22aa1c4df22d84d37c9cb84ceffae9b6c0e4"
    ["7.3.0/amd64"]="65091094eadb7e0211812895d2425f67d82750df7c7e018f6541dd292c7cf7fcc11cdbd6daf6e8b978f1abe22f24e3cfbd8e3adebe63b76bea614720379838f7"
    ["7.3.0/arm64"]="46e9e04971aed22fadbbf137169b777cb4879710bdbcb8d9f22047058e7324b1edb2015968b0080d0f6db7d2f26727ea392501dec1b0885d99a58289db6de5e6"
    ["7.2.0/amd64"]="26efda98ad173b9dda177c35aa7ae54939e5130c882f8b71ba730f0d949d5c0c141e57bcb1ef743c30b052056bf0edc1d246107211dc7a55fc34050ae56d4b2c"
    ["7.2.0/arm64"]="ee67a7f097453d1fdbf48b8f7700f7379869b3d5cf66a522d7ef4a69f7eb2b3eaf99b713d2ac8b8c6bf6b0679c75276c2dd518c01f2e00c0ce5ce8d4ad4f687b"
    ["7.1.0/amd64"]="b949ada762600e08e58a9fdb35a0def8747c13178123f5aa5375dda6c7ff831a644c7cbb333fc13abfd287092e55fbb5f531a2419d6e959f80fedaf6a2b71031"
    ["7.1.0/arm64"]="4f046daa38c5ed394ff33e202bbae032b588498bce57b642dadf2986c034f3494989a3203526006813c55373adaecce0dd8fbcb04fcf93f9106d1b13ea5ebf0d"
    ["7.0.2/amd64"]="b9ffde05f7c0d375445a638cfa7063c6f46f30d167420a7eb911ddf31198211441537067eff44969cab9920a7cbdc2c46d7ad52f3a855d864c6ea75f85c0438a"
    ["7.0.2/arm64"]="d381bd7dc248c0fabbc2c85b0c1dc8777ce134affeab7ddeb6806c30feb5287ffacc566bbe2cc008cea4840498583e49eac321cd2d46049d54503aebd66663bc"
    ["7.0.1/amd64"]="d485ef8c0b3eeeef291d360e6437e924583b68cbbd7a85ece41b0c0dd7ec002a045f0d56bbb662efbcb4db9963416f5d06693732f4629495a0bb6680ba8d1593"
    ["7.0.1/arm64"]="c15773cca43c5cf2f3f9252705c5619c4650523270996bd708eb4b4073d260985f37ee1947d454877515090ef7b009f3ffdc1500fae819305537aaea95ef9783"
    ["7.0.0/amd64"]="e94bc7866240a742b901b9a0b135531e4efd082b742c8e5e46dea9b6198ba41a839fd8868cb0b4f6ccdbf32f385a020ce88bbbf593876384b853f25409bdd0f8"
    ["7.0.0/arm64"]="f2ecdb43fe9e661b9fdfa19bee5b6ee2a1bf454793da9b7544d4b2efb79613487be67add49c91b69ef98b289316e620102058e7c1b7e4b38d777a1168442532f"
)
# <<< checksum table <<<

orb_install_main
