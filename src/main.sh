#!/bin/bash

# A thin layer over tf_plan_format: install the given version, render the plan files with `tf_plan_format github`.
# Runs under macOS's /bin/bash 3.2 too: no mapfile, no associative arrays, no empty "${ARRAY[@]}" under set -u.
# Functions return values through globals rather than $(...): bash clears set -e inside command substitutions.
set -euo pipefail

RELEASES_URL="https://github.com/ovsds/tf-plan-format/releases"

function print_info() {
    local MESSAGE=$1
    echo "INFO: ${MESSAGE}"
}

function print_error() {
    local MESSAGE=$1
    echo "ERROR:: ${MESSAGE}"
}

function fail() {
    print_error "$1"
    exit 1
}

function set_output() {
    GITHUB_OUTPUT=${GITHUB_OUTPUT:?"GITHUB_OUTPUT is not set"}

    local KEY=$1
    local VALUE=$2

    # A random delimiter: the rendered plan may hold a line equal to a fixed one
    local DELIMITER="EOF_${RANDOM}${RANDOM}${RANDOM}"
    print_info "Setting output: ${KEY}"
    {
        echo "${KEY}<<${DELIMITER}"
        echo "${VALUE}"
        echo "${DELIMITER}"
    } >> "${GITHUB_OUTPUT}"
}

function resolve_platform() {
    local OS
    local ARCH

    case "${RUNNER_OS:-}" in
        Linux) OS="linux" ;;
        macOS) OS="darwin" ;;
        *) fail "Unsupported runner OS: ${RUNNER_OS:-}, tf-plan-format is released for Linux and macOS" ;;
    esac

    case "${RUNNER_ARCH:-}" in
        X64) ARCH="amd64" ;;
        ARM64) ARCH="arm64" ;;
        *) fail "Unsupported runner architecture: ${RUNNER_ARCH:-}, tf-plan-format is released for X64 and ARM64" ;;
    esac

    PLATFORM="${OS}-${ARCH}"
}

function sha256() {
    local FILE=$1

    if command -v sha256sum > /dev/null; then
        sha256sum "${FILE}"
    else
        shasum -a 256 "${FILE}"
    fi | cut -d " " -f 1
}

function download() {
    local NAME=$1
    local DIR=$2

    local URL="${RELEASES_URL}/download/${INPUT_VERSION}/${NAME}"
    print_info "Downloading ${URL}"
    if ! curl --fail --silent --show-error --location --retry 3 --output "${DIR}/${NAME}" "${URL}"; then
        fail "Failed to download ${URL}"
    fi
}

function install() {
    local INSTALL_DIR=$1

    local ASSET="tf_plan_format-${INPUT_VERSION}-${PLATFORM}.tar.gz"
    local DOWNLOAD_DIR
    DOWNLOAD_DIR=$(mktemp -d "${RUNNER_TEMP}/tf-plan-format-download.XXXXXX")
    download "${ASSET}" "${DOWNLOAD_DIR}"
    download checksums.txt "${DOWNLOAD_DIR}"

    local EXPECTED
    EXPECTED=$(awk -v asset="${ASSET}" '$2 == asset || $2 == "*" asset { print $1; exit }' "${DOWNLOAD_DIR}/checksums.txt")
    local ACTUAL
    ACTUAL=$(sha256 "${DOWNLOAD_DIR}/${ASSET}")
    if [[ -z "${EXPECTED}" || "${ACTUAL}" != "${EXPECTED}" ]]; then
        fail "Checksum mismatch for ${ASSET}: expected ${EXPECTED:-no checksums.txt entry}, got ${ACTUAL}"
    fi

    mkdir -p "${INSTALL_DIR}"
    if ! tar -xzf "${DOWNLOAD_DIR}/${ASSET}" -C "${INSTALL_DIR}" tf_plan_format; then
        fail "Failed to unpack tf_plan_format from ${ASSET}"
    fi
    rm -rf "${DOWNLOAD_DIR}"
}

function resolve_binary() {
    resolve_platform
    local INSTALL_DIR="${RUNNER_TEMP}/tf-plan-format/${INPUT_VERSION}"
    if [[ ! -x "${INSTALL_DIR}/tf_plan_format" ]]; then
        install "${INSTALL_DIR}"
    fi
    print_info "Using tf-plan-format ${INPUT_VERSION}"
    BINARY="${INSTALL_DIR}/tf_plan_format"
}

function add_file_arg() {
    local FILE=$1

    FILE="${FILE#"${FILE%%[![:space:]]*}"}"
    FILE="${FILE%"${FILE##*[![:space:]]}"}"
    if [[ -n "${FILE}" ]]; then
        CLI_ARGS+=(--file "${FILE}")
    fi
}

function build_cli_args() {
    CLI_ARGS=(github)

    local REST="${INPUT_PLAN_FILES}"
    while [[ "${REST}" == *"${INPUT_PLAN_FILES_SEPARATOR}"* ]]; do
        add_file_arg "${REST%%"${INPUT_PLAN_FILES_SEPARATOR}"*}"
        REST=${REST#*"${INPUT_PLAN_FILES_SEPARATOR}"}
    done
    add_file_arg "${REST}"
}

function main() {
    INPUT_PLAN_FILES=${INPUT_PLAN_FILES:?"INPUT_PLAN_FILES is not set"}
    INPUT_PLAN_FILES_SEPARATOR=${INPUT_PLAN_FILES_SEPARATOR:?"INPUT_PLAN_FILES_SEPARATOR is not set"}
    INPUT_VERSION=${INPUT_VERSION:?"INPUT_VERSION is not set"}
    RUNNER_TEMP=${RUNNER_TEMP:?"RUNNER_TEMP is not set"}

    resolve_binary
    build_cli_args

    local OUTPUT_DIR
    OUTPUT_DIR=$(mktemp -d "${RUNNER_TEMP}/tf-plan-format-action.XXXXXX")
    local RENDERED_PLAN_PATH="${OUTPUT_DIR}/rendered-plan.md"
    if ! "${BINARY}" "${CLI_ARGS[@]}" > "${RENDERED_PLAN_PATH}"; then
        fail "tf_plan_format failed to render the plans"
    fi

    local RENDERED_PLAN
    RENDERED_PLAN=$(cat "${RENDERED_PLAN_PATH}")
    set_output "rendered-plan" "${RENDERED_PLAN}"
    set_output "rendered-plan-path" "${RENDERED_PLAN_PATH}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
