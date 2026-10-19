#!/bin/bash

# A thin layer between the caller and tf_plan_format: install it, pass the inputs to it as flags, put the comment
# marker and title on top. Inputs are not validated here: tf_plan_format and the comment step report their own errors.
# Runs under macOS's /bin/bash 3.2 too: no mapfile, no associative arrays, no empty "${ARRAY[@]}" under set -u.
# Functions return values through globals rather than $(...): bash clears set -e inside command substitutions.
set -euo pipefail

RELEASES_URL="https://github.com/ovsds/tf-plan-format/releases"
MARKER_PREFIX="tf-plan-format-action"

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

    # A random delimiter: a fixed one inside VALUE (from comment-key or title) would end it and inject other outputs
    local DELIMITER="EOF_${RANDOM}${RANDOM}${RANDOM}"
    print_info "Setting output: ${KEY}=${VALUE}"
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

function resolve_version() {
    VERSION=${INPUT_VERSION}
    if [[ "${VERSION}" != "latest" ]]; then
        return
    fi

    # The latest release page redirects to its tag: no API call and no token
    local URL
    if ! URL=$(curl --fail --silent --show-error --location --retry 3 --head --output /dev/null \
        --write-out "%{url_effective}" "${RELEASES_URL}/latest"); then
        fail "Failed to resolve the latest tf-plan-format release"
    fi
    if [[ "${URL}" != */releases/tag/* ]]; then
        fail "Failed to resolve the latest tf-plan-format release: ${RELEASES_URL}/latest led to ${URL}, not a release tag"
    fi
    VERSION=${URL##*/}
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

    local URL="${RELEASES_URL}/download/${VERSION}/${NAME}"
    print_info "Downloading ${URL}"
    if ! curl --fail --silent --show-error --location --retry 3 --output "${DIR}/${NAME}" "${URL}"; then
        fail "Failed to download ${URL}: a new release may still be uploading its assets, retry in a few minutes or set version"
    fi
}

function install() {
    local INSTALL_DIR=$1

    local ASSET="tf_plan_format-${VERSION}-${PLATFORM}.tar.gz"
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
    # Lets the tests render with a stub or a locally built binary
    if [[ -n "${TF_PLAN_FORMAT_ACTION_TEST_BINARY:-}" ]]; then
        print_info "Using test binary ${TF_PLAN_FORMAT_ACTION_TEST_BINARY}"
        BINARY="${TF_PLAN_FORMAT_ACTION_TEST_BINARY}"
        return
    fi

    resolve_platform
    resolve_version

    local INSTALL_DIR="${RUNNER_TEMP}/tf-plan-format/${VERSION}"
    if [[ ! -x "${INSTALL_DIR}/tf_plan_format" ]]; then
        install "${INSTALL_DIR}"
    fi
    print_info "Using tf-plan-format ${VERSION}"
    BINARY="${INSTALL_DIR}/tf_plan_format"
}

function build_cli_args() {
    CLI_ARGS=(github)

    local FILE
    while IFS= read -r FILE || [[ -n "${FILE}" ]]; do
        FILE="${FILE#"${FILE%%[![:space:]]*}"}"
        FILE="${FILE%"${FILE##*[![:space:]]}"}"
        if [[ -n "${FILE}" ]]; then
            CLI_ARGS+=(--file "${FILE}")
        fi
    done <<< "${INPUT_FILES}"

    if [[ "${INPUT_CHANGED_VALUES}" == "true" ]]; then
        CLI_ARGS+=(--changed-values)
    fi
    if [[ "${INPUT_SHOW_NO_OP}" == "true" ]]; then
        CLI_ARGS+=(--show-no-op)
    fi
    if [[ "${INPUT_SHOW_READ}" == "true" ]]; then
        CLI_ARGS+=(--show-read)
    fi
    if [[ -n "${INPUT_MAX_LENGTH}" ]]; then
        CLI_ARGS+=(--max-length "${INPUT_MAX_LENGTH}")
    fi
}

function main() {
    INPUT_FILES=${INPUT_FILES:-}
    INPUT_VERSION=${INPUT_VERSION:-latest}
    INPUT_MAX_LENGTH=${INPUT_MAX_LENGTH:-}
    INPUT_CHANGED_VALUES=${INPUT_CHANGED_VALUES:-}
    INPUT_SHOW_NO_OP=${INPUT_SHOW_NO_OP:-}
    INPUT_SHOW_READ=${INPUT_SHOW_READ:-}
    INPUT_TITLE=${INPUT_TITLE:-}
    INPUT_COMMENT_KEY=${INPUT_COMMENT_KEY:-}
    RUNNER_TEMP=${RUNNER_TEMP:?"RUNNER_TEMP is not set"}

    resolve_binary
    build_cli_args

    local MARKER="<!-- ${MARKER_PREFIX}:${INPUT_COMMENT_KEY} -->"
    local OUTPUT_DIR
    OUTPUT_DIR=$(mktemp -d "${RUNNER_TEMP}/tf-plan-format-action.XXXXXX")
    local MARKDOWN_PATH="${OUTPUT_DIR}/plan.md"
    {
        echo "${MARKER}"
        echo "## ${INPUT_TITLE}"
        echo
    } > "${MARKDOWN_PATH}"
    if ! "${BINARY}" "${CLI_ARGS[@]}" >> "${MARKDOWN_PATH}"; then
        fail "tf_plan_format failed to render the plans"
    fi

    set_output "markdown-path" "${MARKDOWN_PATH}"
    set_output "marker" "${MARKER}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
