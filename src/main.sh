#!/bin/bash

# Runs under macOS's /bin/bash 3.2 too: no mapfile, no associative arrays, no empty "${ARRAY[@]}" under set -u.
# Functions return values through globals rather than $(...): bash clears set -e inside command substitutions.
set -euo pipefail

TF_PLAN_FORMAT_REPOSITORY="ovsds/tf-plan-format"
# The newest releases checked for a complete set of assets when resolving latest
LATEST_RELEASES_CHECKED=10
GITHUB_COM_API_URL="https://api.github.com"
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

    print_info "Setting output: ${KEY}=${VALUE}"
    {
        echo "${KEY}<<EOF"
        echo "${VALUE}"
        echo "EOF"
    } >> "${GITHUB_OUTPUT}"
}

function validate_boolean() {
    local NAME=$1
    local VALUE=$2

    if [[ "${VALUE}" != "true" && "${VALUE}" != "false" ]]; then
        fail "Input ${NAME} must be true or false, got: ${VALUE}"
    fi
}

function validate_inputs() {
    if [[ -z "${INPUT_TITLE}" ]]; then
        fail "Input title must not be empty"
    fi
    if [[ -z "${INPUT_COMMENT_KEY}" ]]; then
        fail "Input comment-key must not be empty"
    fi

    validate_boolean "changed-values" "${INPUT_CHANGED_VALUES}"
    validate_boolean "show-no-op" "${INPUT_SHOW_NO_OP}"
    validate_boolean "show-read" "${INPUT_SHOW_READ}"
    validate_boolean "comment" "${INPUT_COMMENT}"

    if [[ ! "${INPUT_MAX_LENGTH}" =~ ^[1-9][0-9]*$ ]]; then
        fail "Input max-length must be a positive integer, got: ${INPUT_MAX_LENGTH}"
    fi

    # The key goes inside an HTML comment: it must not be able to close it or break the line
    if [[ ! "${INPUT_COMMENT_KEY}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        fail "Input comment-key may contain only letters, digits, '.', '_' and '-', got: ${INPUT_COMMENT_KEY}"
    fi

    if [[ "${INPUT_TITLE}" == *$'\n'* ]]; then
        fail "Input title must be a single line"
    fi

    if [[ "${INPUT_COMMENT}" == "true" ]]; then
        if [[ -z "${INPUT_ISSUE_NUMBER}" ]]; then
            fail "Input comment is true, but there is no pull request to comment on: run on a pull_request event, set issue-number, or set comment to false"
        fi
        if [[ ! "${INPUT_ISSUE_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
            fail "Input issue-number must be a positive integer, got: ${INPUT_ISSUE_NUMBER}"
        fi
    fi
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

function validate_version() {
    local VERSION=$1
    # Where the version came from, for the errors: the version input or the release latest resolved to
    local SOURCE=$2

    if [[ "${VERSION}" =~ ^v[0-9] ]]; then
        fail "${SOURCE} must not have the v prefix, tf-plan-format release tags are plain versions like 0.1.0, got: ${VERSION}"
    fi
    if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
        fail "${SOURCE} must be a release tag like 0.1.0, got: ${VERSION}"
    fi
}

function resolve_latest_version() {
    local CURL_ARGS=(
        --fail --silent --show-error --location --retry 3
        --header "Accept: application/vnd.github+json"
    )
    # A GitHub Enterprise Server token is not valid on github.com and must not be sent there
    if [[ -n "${INPUT_TOKEN}" && "${GITHUB_API_URL:-${GITHUB_COM_API_URL}}" == "${GITHUB_COM_API_URL}" ]]; then
        CURL_ARGS+=(--header "Authorization: Bearer ${INPUT_TOKEN}")
    fi

    local RESPONSE
    if ! RESPONSE=$(curl "${CURL_ARGS[@]}" "${GITHUB_COM_API_URL}/repos/${TF_PLAN_FORMAT_REPOSITORY}/releases?per_page=${LATEST_RELEASES_CHECKED}"); then
        fail "Failed to resolve the latest ${TF_PLAN_FORMAT_REPOSITORY} release"
    fi

    # The release workflow uploads the archives minutes after publishing the release: skip releases without them yet.
    # API order is by creation date, not version: pick the highest plain X.Y.Z tag; unlike $, \z lets no trailing newline through
    # $tag and $platform are jq variables
    # shellcheck disable=SC2016
    local FILTER='
        if type != "array" then error("not a list of releases") else . end
        | map(select((.draft | not) and (.prerelease | not)))
        | "\(length) \(
            map(
                .tag_name as $tag
                | select($tag | test("\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z"))
                | select(
                    any(.assets[]; .name == "tf_plan_format-\($tag)-\($platform).tar.gz" and .state == "uploaded")
                    and any(.assets[]; .name == "checksums.txt" and .state == "uploaded")
                )
            )
            | max_by(.tag_name | split(".") | map(tonumber))
            | .tag_name // ""
        )"
    '
    local RESOLVED
    if ! RESOLVED=$(jq --raw-output --arg platform "${PLATFORM}" "${FILTER}" <<< "${RESPONSE}"); then
        fail "Failed to resolve the latest ${TF_PLAN_FORMAT_REPOSITORY} release: the GitHub API reply is not a list of releases"
    fi
    local PUBLISHED
    read -r PUBLISHED VERSION <<< "${RESOLVED}"
    if [[ "${PUBLISHED}" -eq 0 ]]; then
        fail "${TF_PLAN_FORMAT_REPOSITORY} has no published release yet; set version or retry once one is published"
    fi
    if [[ -z "${VERSION}" ]]; then
        fail "None of the latest ${LATEST_RELEASES_CHECKED} ${TF_PLAN_FORMAT_REPOSITORY} releases has both tf_plan_format-<version>-${PLATFORM}.tar.gz and checksums.txt uploaded: a new release may still be uploading its assets, retry later or set version"
    fi
}

function sha256() {
    local FILE=$1

    if command -v sha256sum > /dev/null; then
        sha256sum "${FILE}"
    else
        shasum -a 256 "${FILE}"
    fi | cut -d " " -f 1
}

function verify_checksum() {
    local DIR=$1
    local ASSET=$2

    local EXPECTED
    EXPECTED=$(awk -v asset="${ASSET}" '$2 == asset || $2 == "*" asset { print $1; exit }' "${DIR}/checksums.txt")
    if [[ -z "${EXPECTED}" ]]; then
        fail "checksums.txt has no entry for ${ASSET}"
    fi

    local ACTUAL
    ACTUAL=$(sha256 "${DIR}/${ASSET}")
    if [[ "${ACTUAL}" != "${EXPECTED}" ]]; then
        fail "Checksum mismatch for ${ASSET}: expected ${EXPECTED}, got ${ACTUAL}"
    fi
}

function unpack() {
    local ARCHIVE=$1
    local INSTALL_DIR=$2

    mkdir -p "${INSTALL_DIR}"
    if ! tar -xzf "${ARCHIVE}" -C "${INSTALL_DIR}" tf_plan_format; then
        fail "Failed to unpack tf_plan_format from ${ARCHIVE}"
    fi
}

function download() {
    local URL=$1
    local OUTPUT=$2
    local NOT_FOUND_HINT=$3

    local STATUS
    if STATUS=$(curl --fail --silent --show-error --location --retry 3 --output "${OUTPUT}" --write-out "%{http_code}" "${URL}"); then
        return
    fi
    if [[ "${STATUS}" == "404" ]]; then
        fail "Failed to download ${URL}: not found, ${NOT_FOUND_HINT}"
    fi
    fail "Failed to download ${URL}"
}

function install() {
    local VERSION=$1
    local INSTALL_DIR=$2

    local ASSET="tf_plan_format-${VERSION}-${PLATFORM}.tar.gz"
    local RELEASE_URL="https://github.com/${TF_PLAN_FORMAT_REPOSITORY}/releases/download/${VERSION}"
    local NOT_FOUND_HINT="release ${VERSION} may not exist or may still be uploading its assets, retry in a few minutes"

    local DOWNLOAD_DIR
    DOWNLOAD_DIR=$(mktemp -d "${RUNNER_TEMP}/tf-plan-format-download.XXXXXX")

    print_info "Downloading ${RELEASE_URL}/${ASSET}"
    download "${RELEASE_URL}/${ASSET}" "${DOWNLOAD_DIR}/${ASSET}" "${NOT_FOUND_HINT}"
    download "${RELEASE_URL}/checksums.txt" "${DOWNLOAD_DIR}/checksums.txt" "${NOT_FOUND_HINT}"
    verify_checksum "${DOWNLOAD_DIR}" "${ASSET}"
    unpack "${DOWNLOAD_DIR}/${ASSET}" "${INSTALL_DIR}"
    rm -rf "${DOWNLOAD_DIR}"
}

function resolve_binary() {
    # Lets the tests render with a locally built binary while no release exists yet
    if [[ -n "${TF_PLAN_FORMAT_ACTION_TEST_BINARY:-}" ]]; then
        print_info "Using test binary ${TF_PLAN_FORMAT_ACTION_TEST_BINARY}"
        BINARY="${TF_PLAN_FORMAT_ACTION_TEST_BINARY}"
        return
    fi

    resolve_platform
    VERSION=${INPUT_VERSION}
    if [[ "${VERSION}" == "latest" ]]; then
        resolve_latest_version
        validate_version "${VERSION}" "The tag of the latest ${TF_PLAN_FORMAT_REPOSITORY} release"
    else
        validate_version "${VERSION}" "Input version"
    fi

    local INSTALL_DIR="${RUNNER_TEMP}/tf-plan-format/${VERSION}"
    if [[ ! -x "${INSTALL_DIR}/tf_plan_format" ]]; then
        install "${VERSION}" "${INSTALL_DIR}"
    fi
    print_info "Using tf-plan-format ${VERSION}"
    BINARY="${INSTALL_DIR}/tf_plan_format"
}

function build_cli_args() {
    local MAX_LENGTH=$1

    CLI_ARGS=(github)

    local FILE
    while IFS= read -r FILE || [[ -n "${FILE}" ]]; do
        FILE="${FILE#"${FILE%%[![:space:]]*}"}"
        FILE="${FILE%"${FILE##*[![:space:]]}"}"
        if [[ -n "${FILE}" ]]; then
            CLI_ARGS+=(--file "${FILE}")
        fi
    done <<< "${INPUT_FILES}"

    if [[ "${#CLI_ARGS[@]}" -eq 1 ]]; then
        fail "Input files must list at least one plan JSON path or glob"
    fi

    if [[ "${INPUT_CHANGED_VALUES}" == "true" ]]; then
        CLI_ARGS+=(--changed-values)
    fi
    if [[ "${INPUT_SHOW_NO_OP}" == "true" ]]; then
        CLI_ARGS+=(--show-no-op)
    fi
    if [[ "${INPUT_SHOW_READ}" == "true" ]]; then
        CLI_ARGS+=(--show-read)
    fi
    CLI_ARGS+=(--max-length "${MAX_LENGTH}")
}

function plan_max_length() {
    local HEADER_LENGTH=$1

    # max-length budgets the whole comment: the header goes first and the CLI does not count its trailing newline
    PLAN_MAX_LENGTH=$((INPUT_MAX_LENGTH - HEADER_LENGTH - 1))
    if [[ "${PLAN_MAX_LENGTH}" -lt 1 ]]; then
        fail "Input max-length ${INPUT_MAX_LENGTH} leaves no room for the plans after the ${HEADER_LENGTH}-byte marker and title heading"
    fi
}

function render() {
    local OUTPUT=$1

    {
        echo "${MARKER}"
        echo "## ${INPUT_TITLE}"
        echo
    } > "${OUTPUT}"

    # wc counts bytes whatever the locale, unlike ${#VAR}
    local HEADER_LENGTH
    HEADER_LENGTH=$(wc -c < "${OUTPUT}")
    plan_max_length "$((HEADER_LENGTH))"
    build_cli_args "${PLAN_MAX_LENGTH}"

    if ! "${BINARY}" "${CLI_ARGS[@]}" >> "${OUTPUT}"; then
        fail "tf_plan_format failed to render the plans"
    fi
}

function main() {
    INPUT_FILES=${INPUT_FILES:-}
    # Empty inputs are reported by validate_inputs and validate_version in the action's own words
    INPUT_VERSION=${INPUT_VERSION:-}
    INPUT_MAX_LENGTH=${INPUT_MAX_LENGTH:-}
    INPUT_CHANGED_VALUES=${INPUT_CHANGED_VALUES:-}
    INPUT_SHOW_NO_OP=${INPUT_SHOW_NO_OP:-}
    INPUT_SHOW_READ=${INPUT_SHOW_READ:-}
    INPUT_TITLE=${INPUT_TITLE:-}
    INPUT_COMMENT=${INPUT_COMMENT:-}
    INPUT_COMMENT_KEY=${INPUT_COMMENT_KEY:-}
    INPUT_ISSUE_NUMBER=${INPUT_ISSUE_NUMBER:-}
    INPUT_TOKEN=${INPUT_TOKEN:-}
    RUNNER_TEMP=${RUNNER_TEMP:?"RUNNER_TEMP is not set"}

    validate_inputs
    MARKER="<!-- ${MARKER_PREFIX}:${INPUT_COMMENT_KEY} -->"

    resolve_binary

    local OUTPUT_DIR
    OUTPUT_DIR=$(mktemp -d "${RUNNER_TEMP}/tf-plan-format-action.XXXXXX")
    local MARKDOWN_PATH="${OUTPUT_DIR}/plan.md"
    render "${MARKDOWN_PATH}"

    set_output "markdown-path" "${MARKDOWN_PATH}"
    set_output "marker" "${MARKER}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
