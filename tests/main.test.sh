#!/bin/bash

# Tests src/main.sh up to the network: downloads are left to the e2e workflow.
# Set TF_PLAN_FORMAT_ACTION_TEST_BINARY to a tf_plan_format binary to also render the plan fixtures with it.
# PLATFORM, BINARY and CLI_ARGS are assigned by the sourced src/main.sh, which shellcheck does not follow here.
# shellcheck disable=SC2154
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SMOKE_BINARY=${TF_PLAN_FORMAT_ACTION_TEST_BINARY:-}
unset TF_PLAN_FORMAT_ACTION_TEST_BINARY

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

FAILED=0
PASSED=0

function assert_equals() {
    local EXPECTED=$1
    local ACTUAL=$2

    if [[ "${EXPECTED}" != "${ACTUAL}" ]]; then
        echo "expected: ${EXPECTED}"
        echo "actual:   ${ACTUAL}"
        return 1
    fi
}

function assert_contains() {
    local HAYSTACK=$1
    local NEEDLE=$2

    if [[ "${HAYSTACK}" != *"${NEEDLE}"* ]]; then
        echo "expected to contain: ${NEEDLE}"
        echo "actual: ${HAYSTACK}"
        return 1
    fi
}

function assert_fails_with() {
    local MESSAGE=$1
    shift

    local OUTPUT
    if OUTPUT=$("$@" 2>&1); then
        echo "expected to fail: $*"
        echo "output: ${OUTPUT}"
        return 1
    fi
    assert_contains "${OUTPUT}" "${MESSAGE}"
}

function setup() {
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/src/main.sh"

    TEST_DIR=$(mktemp -d "${TEST_ROOT}/test.XXXXXX")
    export RUNNER_TEMP="${TEST_DIR}/runner_temp"
    export GITHUB_OUTPUT="${TEST_DIR}/github_output"
    mkdir -p "${RUNNER_TEMP}"
    touch "${GITHUB_OUTPUT}"

    export INPUT_FILES="plan.json"
    export INPUT_VERSION="latest"
    export INPUT_MAX_LENGTH="65000"
    export INPUT_CHANGED_VALUES="false"
    export INPUT_SHOW_NO_OP="false"
    export INPUT_SHOW_READ="false"
    export INPUT_TITLE="Plan"
    export INPUT_COMMENT="true"
    export INPUT_COMMENT_KEY="default"
    export INPUT_ISSUE_NUMBER="1"
    export INPUT_TOKEN=""
    export RUNNER_OS="Linux"
    export RUNNER_ARCH="X64"
}

function get_output() {
    local KEY=$1
    sed -n "/^${KEY}<<EOF$/{n;p;}" "${GITHUB_OUTPUT}"
}

function join_cli_args() {
    local IFS="|"
    echo "${CLI_ARGS[*]}"
}

function write_stub_binary() {
    local TARGET=$1
    local EXIT_CODE=$2

    cat > "${TARGET}" << EOF
#!/bin/bash
printf '%s\n' "\$@"
exit ${EXIT_CODE}
EOF
    chmod +x "${TARGET}"
}

# Stands in for curl on PATH: records its arguments and prints STDOUT, the response or the --write-out status
function write_fake_curl() {
    local STDOUT=$1
    local EXIT_CODE=$2

    mkdir -p "${TEST_DIR}/bin"
    printf '%s' "${STDOUT}" > "${TEST_DIR}/curl_stdout"
    cat > "${TEST_DIR}/bin/curl" << EOF
#!/bin/bash
printf '%s\n' "\$@" > "${TEST_DIR}/curl_args"
cat "${TEST_DIR}/curl_stdout"
exit ${EXIT_CODE}
EOF
    chmod +x "${TEST_DIR}/bin/curl"
    export PATH="${TEST_DIR}/bin:${PATH}"
}

# Appends a release to RELEASES, the comma-separated items of the fake releases API reply.
# Assets are names, uploaded, or name:state like checksums.txt:new.
function add_release() {
    local TAG=$1
    local DRAFT=$2
    local PRERELEASE=$3
    shift 3

    local ASSETS=""
    local ASSET
    for ASSET in "$@"; do
        local STATE="uploaded"
        if [[ "${ASSET}" == *:* ]]; then
            STATE=${ASSET#*:}
        fi
        ASSETS="${ASSETS:+${ASSETS},}{\"name\": \"${ASSET%%:*}\", \"state\": \"${STATE}\"}"
    done
    local RELEASE="{\"tag_name\": \"${TAG}\", \"draft\": ${DRAFT}, \"prerelease\": ${PRERELEASE}, \"assets\": [${ASSETS}]}"
    RELEASES="${RELEASES:+${RELEASES},}${RELEASE}"
}

function run_test() {
    local NAME=$1
    local LOG="${TEST_ROOT}/${NAME}.log"

    # Not under if/||: bash ignores set -e in the whole subshell then, and a failed assert would not stop the test
    set +e
    (
        set -e
        setup
        "${NAME}"
    ) > "${LOG}" 2>&1
    local STATUS=$?
    set -e

    if [[ "${STATUS}" -eq 0 ]]; then
        echo "PASS ${NAME}"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL ${NAME}"
        sed 's/^/    /' "${LOG}"
        FAILED=$((FAILED + 1))
    fi
}

function test_validate_inputs_accepts_defaults() {
    validate_inputs
}

function test_validate_inputs_rejects_non_boolean() {
    INPUT_SHOW_READ="yes"
    assert_fails_with "Input show-read must be true or false, got: yes" validate_inputs
}

function test_validate_inputs_rejects_bad_max_length() {
    INPUT_MAX_LENGTH="0"
    assert_fails_with "Input max-length must be a positive integer, got: 0" validate_inputs
    INPUT_MAX_LENGTH="65k"
    assert_fails_with "Input max-length must be a positive integer, got: 65k" validate_inputs
}

function test_validate_inputs_rejects_unsafe_comment_key() {
    INPUT_COMMENT_KEY="a -->"
    assert_fails_with "Input comment-key may contain only" validate_inputs
}

function test_validate_inputs_rejects_multiline_title() {
    INPUT_TITLE=$'Plan\nInjected'
    assert_fails_with "Input title must be a single line" validate_inputs
}

function test_validate_inputs_requires_issue_number_to_comment() {
    INPUT_ISSUE_NUMBER=""
    assert_fails_with "there is no pull request to comment on" validate_inputs
    INPUT_COMMENT="false"
    validate_inputs
}

function test_validate_inputs_rejects_bad_issue_number() {
    INPUT_ISSUE_NUMBER="abc"
    assert_fails_with "Input issue-number must be a positive integer, got: abc" validate_inputs
    INPUT_ISSUE_NUMBER="0"
    assert_fails_with "Input issue-number must be a positive integer, got: 0" validate_inputs
    INPUT_COMMENT="false"
    validate_inputs
}

function test_main_rejects_empty_title() {
    INPUT_TITLE=""
    assert_fails_with "Input title must not be empty" main
}

function test_main_rejects_empty_comment_key() {
    INPUT_COMMENT_KEY=""
    assert_fails_with "Input comment-key must not be empty" main
}

function test_main_rejects_empty_max_length() {
    INPUT_MAX_LENGTH=""
    assert_fails_with "Input max-length must be a positive integer, got: " main
}

function test_resolve_platform_maps_runners() {
    RUNNER_OS="Linux" RUNNER_ARCH="X64" resolve_platform
    assert_equals "linux-amd64" "${PLATFORM}"
    RUNNER_OS="Linux" RUNNER_ARCH="ARM64" resolve_platform
    assert_equals "linux-arm64" "${PLATFORM}"
    RUNNER_OS="macOS" RUNNER_ARCH="X64" resolve_platform
    assert_equals "darwin-amd64" "${PLATFORM}"
    RUNNER_OS="macOS" RUNNER_ARCH="ARM64" resolve_platform
    assert_equals "darwin-arm64" "${PLATFORM}"
}

function test_resolve_platform_rejects_unsupported_runners() {
    RUNNER_OS="Windows"
    assert_fails_with "Unsupported runner OS: Windows" resolve_platform
    RUNNER_OS="Linux"
    RUNNER_ARCH="ARM"
    assert_fails_with "Unsupported runner architecture: ARM" resolve_platform
}

function test_validate_version() {
    validate_version "0.1.0" "Input version"
    validate_version "1.2.3-rc.1" "Input version"
    assert_fails_with "Input version must not have the v prefix" validate_version "v0.1.0" "Input version"
    assert_fails_with "Input version must be a release tag like 0.1.0, got: main" validate_version "main" "Input version"
}

function test_resolve_binary_names_input_on_bad_version() {
    INPUT_VERSION="main"
    assert_fails_with "Input version must be a release tag like 0.1.0, got: main" resolve_binary
}

function test_resolve_binary_names_resolved_release_on_bad_tag() {
    # The release filter keeps such tags out; this stands in for a filter that lets one through.
    # resolve_binary calls it.
    # shellcheck disable=SC2329
    function resolve_latest_version() {
        VERSION="v1.0.0"
    }

    local OUTPUT
    if OUTPUT=$(resolve_binary 2>&1); then
        echo "expected to fail"
        return 1
    fi
    assert_contains "${OUTPUT}" "The tag of the latest ovsds/tf-plan-format release must not have the v prefix"
    [[ "${OUTPUT}" != *"Input version"* ]] || return 1
}

function prepare_release_dir() {
    local DIR=$1
    local ASSET=$2

    mkdir -p "${DIR}/content"
    write_stub_binary "${DIR}/content/tf_plan_format" 0
    tar -czf "${DIR}/${ASSET}" -C "${DIR}/content" tf_plan_format
    local SUM
    SUM=$(sha256 "${DIR}/${ASSET}")
    echo "${SUM}  ${ASSET}" > "${DIR}/checksums.txt"
}

function test_verify_checksum_and_unpack() {
    local ASSET="tf_plan_format-0.1.0-linux-amd64.tar.gz"
    prepare_release_dir "${TEST_DIR}/release" "${ASSET}"

    verify_checksum "${TEST_DIR}/release" "${ASSET}"
    unpack "${TEST_DIR}/release/${ASSET}" "${TEST_DIR}/install"
    [[ -x "${TEST_DIR}/install/tf_plan_format" ]] || return 1
}

function test_verify_checksum_rejects_mismatch() {
    local ASSET="tf_plan_format-0.1.0-linux-amd64.tar.gz"
    prepare_release_dir "${TEST_DIR}/release" "${ASSET}"
    echo "tampered" >> "${TEST_DIR}/release/${ASSET}"

    assert_fails_with "Checksum mismatch for ${ASSET}" verify_checksum "${TEST_DIR}/release" "${ASSET}"
}

function test_verify_checksum_rejects_missing_entry() {
    local ASSET="tf_plan_format-0.1.0-linux-amd64.tar.gz"
    prepare_release_dir "${TEST_DIR}/release" "${ASSET}"

    assert_fails_with "checksums.txt has no entry for tf_plan_format-0.1.0-linux-arm64.tar.gz" \
        verify_checksum "${TEST_DIR}/release" "tf_plan_format-0.1.0-linux-arm64.tar.gz"
}

function test_resolve_binary_reuses_installed_version() {
    INPUT_VERSION="0.1.0"
    mkdir -p "${RUNNER_TEMP}/tf-plan-format/0.1.0"
    write_stub_binary "${RUNNER_TEMP}/tf-plan-format/0.1.0/tf_plan_format" 0

    resolve_binary
    assert_equals "${RUNNER_TEMP}/tf-plan-format/0.1.0/tf_plan_format" "${BINARY}"
}

function test_resolve_latest_version_skips_incomplete_releases() {
    resolve_platform
    local ASSET="linux-amd64.tar.gz"
    RELEASES=""
    add_release "0.4.0" true false "tf_plan_format-0.4.0-${ASSET}" "checksums.txt"
    add_release "0.3.0" false false "checksums.txt"
    add_release "0.2.1" false false "tf_plan_format-0.2.1-${ASSET}"
    add_release "0.2.0-rc.1" false true "tf_plan_format-0.2.0-rc.1-${ASSET}" "checksums.txt"
    add_release "0.1.1" false false "tf_plan_format-0.1.1-darwin-arm64.tar.gz" "checksums.txt"
    add_release "0.1.0" false false "tf_plan_format-0.1.0-${ASSET}" "checksums.txt"
    add_release "0.0.1" false false "tf_plan_format-0.0.1-${ASSET}" "checksums.txt"
    write_fake_curl "[${RELEASES}]" 0

    resolve_latest_version
    assert_equals "0.1.0" "${VERSION}"
    local CURL_ARGS
    CURL_ARGS=$(cat "${TEST_DIR}/curl_args")
    assert_contains "${CURL_ARGS}" "https://api.github.com/repos/ovsds/tf-plan-format/releases?per_page=10"
}

function test_resolve_latest_version_picks_highest_version() {
    resolve_platform
    local ASSET="linux-amd64.tar.gz"
    RELEASES=""
    add_release "0.9.0" false false "tf_plan_format-0.9.0-${ASSET}" "checksums.txt"
    add_release "0.10.0" false false "tf_plan_format-0.10.0-${ASSET}" "checksums.txt"
    add_release "0.2.0" false false "tf_plan_format-0.2.0-${ASSET}" "checksums.txt"
    write_fake_curl "[${RELEASES}]" 0

    resolve_latest_version
    assert_equals "0.10.0" "${VERSION}"
}

function test_resolve_latest_version_skips_assets_not_uploaded() {
    resolve_platform
    local ASSET="linux-amd64.tar.gz"
    RELEASES=""
    add_release "0.3.0" false false "tf_plan_format-0.3.0-${ASSET}:new" "checksums.txt"
    add_release "0.2.0" false false "tf_plan_format-0.2.0-${ASSET}" "checksums.txt:new"
    add_release "0.1.0" false false "tf_plan_format-0.1.0-${ASSET}" "checksums.txt"
    write_fake_curl "[${RELEASES}]" 0

    resolve_latest_version
    assert_equals "0.1.0" "${VERSION}"
}

function test_resolve_latest_version_skips_non_semver_tags() {
    resolve_platform
    local ASSET="linux-amd64.tar.gz"
    RELEASES=""
    add_release "v1.0.0" false false "tf_plan_format-v1.0.0-${ASSET}" "checksums.txt"
    add_release "1.0.0-hotfix" false false "tf_plan_format-1.0.0-hotfix-${ASSET}" "checksums.txt"
    add_release "1.0" false false "tf_plan_format-1.0-${ASSET}" "checksums.txt"
    add_release "0.1.0" false false "tf_plan_format-0.1.0-${ASSET}" "checksums.txt"
    write_fake_curl "[${RELEASES}]" 0

    resolve_latest_version
    assert_equals "0.1.0" "${VERSION}"
}

function test_resolve_latest_version_fails_without_published_release() {
    resolve_platform
    local MESSAGE="ovsds/tf-plan-format has no published release yet; set version or retry once one is published"
    write_fake_curl "[]" 0
    assert_fails_with "${MESSAGE}" resolve_latest_version

    local ASSET="linux-amd64.tar.gz"
    RELEASES=""
    add_release "0.2.0" true false "tf_plan_format-0.2.0-${ASSET}" "checksums.txt"
    add_release "0.1.0-rc.1" false true "tf_plan_format-0.1.0-rc.1-${ASSET}" "checksums.txt"
    write_fake_curl "[${RELEASES}]" 0
    assert_fails_with "${MESSAGE}" resolve_latest_version
}

function test_resolve_latest_version_fails_without_complete_release() {
    resolve_platform
    RELEASES=""
    add_release "0.2.0" false false "tf_plan_format-0.2.0-linux-amd64.tar.gz:open" "checksums.txt"
    add_release "0.1.0" false false "checksums.txt"
    write_fake_curl "[${RELEASES}]" 0

    assert_fails_with "None of the latest 10 ovsds/tf-plan-format releases has both tf_plan_format-<version>-linux-amd64.tar.gz and checksums.txt uploaded: a new release may still be uploading its assets" \
        resolve_latest_version
}

function test_resolve_latest_version_fails_on_non_list_reply() {
    resolve_platform
    write_fake_curl '{"message": "Not Found"}' 0

    assert_fails_with "the GitHub API reply is not a list of releases" resolve_latest_version
}

function test_resolve_latest_version_fails_on_non_json_reply() {
    resolve_platform
    write_fake_curl "<html>rate limited</html>" 0

    assert_fails_with "Failed to resolve the latest ovsds/tf-plan-format release" resolve_latest_version
}

function test_resolve_latest_version_fails_on_api_error() {
    resolve_platform
    write_fake_curl "" 22

    assert_fails_with "Failed to resolve the latest ovsds/tf-plan-format release" resolve_latest_version
}

function test_resolve_binary_hints_at_uploading_release_on_404() {
    INPUT_VERSION="0.1.0"
    write_fake_curl "404" 56

    assert_fails_with "tf_plan_format-0.1.0-linux-amd64.tar.gz: not found, release 0.1.0 may not exist or may still be uploading its assets" \
        resolve_binary
}

function test_download_fails_without_hint_on_other_errors() {
    write_fake_curl "000" 6

    local OUTPUT
    if OUTPUT=$(download "https://example.com/a.tar.gz" "${TEST_DIR}/a.tar.gz" "the hint" 2>&1); then
        echo "expected to fail"
        return 1
    fi
    assert_contains "${OUTPUT}" "Failed to download https://example.com/a.tar.gz"
    [[ "${OUTPUT}" != *"the hint"* ]] || return 1
}

function test_build_cli_args_defaults() {
    INPUT_FILES=$'  plans/a.json  \n\n\tplans/*/plan.json\n'

    build_cli_args 64951
    local ACTUAL
    ACTUAL=$(join_cli_args)
    assert_equals "github|--file|plans/a.json|--file|plans/*/plan.json|--max-length|64951" "${ACTUAL}"
}

function test_build_cli_args_flags() {
    INPUT_CHANGED_VALUES="true"
    INPUT_SHOW_NO_OP="true"
    INPUT_SHOW_READ="true"

    build_cli_args 100
    local ACTUAL
    ACTUAL=$(join_cli_args)
    assert_equals "github|--file|plan.json|--changed-values|--show-no-op|--show-read|--max-length|100" "${ACTUAL}"
}

function test_build_cli_args_requires_files() {
    INPUT_FILES=$'\n  \n'
    assert_fails_with "Input files must list at least one plan JSON path or glob" build_cli_args 100
}

function test_plan_max_length_subtracts_header_and_newline() {
    plan_max_length 48
    assert_equals "64951" "${PLAN_MAX_LENGTH}"
    INPUT_MAX_LENGTH="50"
    plan_max_length 48
    assert_equals "1" "${PLAN_MAX_LENGTH}"
}

function test_plan_max_length_fails_without_room_for_plans() {
    INPUT_MAX_LENGTH="49"
    assert_fails_with "Input max-length 49 leaves no room for the plans after the 48-byte marker and title heading" \
        plan_max_length 48
}

function test_main_budgets_header_in_bytes() {
    write_stub_binary "${TEST_DIR}/tf_plan_format" 0
    export TF_PLAN_FORMAT_ACTION_TEST_BINARY="${TEST_DIR}/tf_plan_format"
    # 8 bytes in UTF-8, 4 characters
    INPUT_TITLE="План"

    main

    local MARKDOWN_PATH
    MARKDOWN_PATH=$(get_output "markdown-path")
    local MARKDOWN
    MARKDOWN=$(cat "${MARKDOWN_PATH}")
    # The header is 38 + 1 + 3 + 8 + 1 + 1 = 52 bytes
    assert_contains "${MARKDOWN}" $'--max-length\n64947'
}

function test_action_passes_comment_author() {
    local ACTION
    ACTION=$(cat "${ROOT_DIR}/action.yaml")
    assert_contains "${ACTION}" $'  comment-author:\n'
    assert_contains "${ACTION}" '    default: "github-actions[bot]"'
    assert_contains "${ACTION}" "        comment-author: \${{ inputs.comment-author }}"
}

function test_main_renders_markdown() {
    write_stub_binary "${TEST_DIR}/tf_plan_format" 0
    export TF_PLAN_FORMAT_ACTION_TEST_BINARY="${TEST_DIR}/tf_plan_format"
    INPUT_TITLE="Production plan"
    INPUT_COMMENT_KEY="prod"

    main

    local MARKDOWN_PATH
    MARKDOWN_PATH=$(get_output "markdown-path")
    assert_contains "${MARKDOWN_PATH}" "${RUNNER_TEMP}/"
    local MARKER_OUTPUT
    MARKER_OUTPUT=$(get_output "marker")
    assert_equals "<!-- tf-plan-format-action:prod -->" "${MARKER_OUTPUT}"
    local MARKDOWN
    MARKDOWN=$(cat "${MARKDOWN_PATH}")
    # The header is 35 + 1 + 18 + 1 + 1 = 56 bytes, the CLI's trailing newline takes 1 more
    assert_equals $'<!-- tf-plan-format-action:prod -->\n## Production plan\n\ngithub\n--file\nplan.json\n--max-length\n64943' \
        "${MARKDOWN}"
}

function test_main_fails_when_cli_fails() {
    write_stub_binary "${TEST_DIR}/tf_plan_format" 65
    export TF_PLAN_FORMAT_ACTION_TEST_BINARY="${TEST_DIR}/tf_plan_format"

    assert_fails_with "tf_plan_format failed to render the plans" main
    [[ ! -s "${GITHUB_OUTPUT}" ]] || return 1
}

function test_main_renders_fixtures_with_real_binary() {
    if [[ -z "${SMOKE_BINARY}" ]]; then
        return 0
    fi
    export TF_PLAN_FORMAT_ACTION_TEST_BINARY="${SMOKE_BINARY}"
    INPUT_FILES=$'tests/plans/create/opentofu.tfplan.json\ntests/plans/u*/opentofu.tfplan.json\ntests/plans/outputs/opentofu.tfplan.json'
    INPUT_COMMENT="false"

    (cd "${ROOT_DIR}" && main)

    local MARKDOWN_PATH
    MARKDOWN_PATH=$(get_output "markdown-path")
    local MARKDOWN
    MARKDOWN=$(cat "${MARKDOWN_PATH}")
    local PREFIX=$'<!-- tf-plan-format-action:default -->\n## Plan\n\n<details>'
    assert_equals "${PREFIX}" "${MARKDOWN:0:${#PREFIX}}"
    assert_contains "${MARKDOWN}" "terraform_data.foo-bar"
    assert_contains "${MARKDOWN}" "create - Plan: 1 to add, 0 to change, 0 to destroy"
    assert_contains "${MARKDOWN}" "update - Plan: 0 to add, 1 to change, 0 to destroy"
    assert_contains "${MARKDOWN}" "Outputs"
}

function test_main_keeps_whole_file_within_max_length_with_real_binary() {
    if [[ -z "${SMOKE_BINARY}" ]]; then
        return 0
    fi
    export TF_PLAN_FORMAT_ACTION_TEST_BINARY="${SMOKE_BINARY}"
    INPUT_FILES=$'tests/plans/create/opentofu.tfplan.json\ntests/plans/u*/opentofu.tfplan.json\ntests/plans/outputs/opentofu.tfplan.json'
    INPUT_COMMENT="false"
    INPUT_MAX_LENGTH="400"

    (cd "${ROOT_DIR}" && main)

    local MARKDOWN_PATH
    MARKDOWN_PATH=$(get_output "markdown-path")
    local LENGTH
    LENGTH=$(wc -c < "${MARKDOWN_PATH}")
    [[ "${LENGTH}" -le 400 ]] || return 1
    # Well under the full render, so the budget was actually spent
    [[ "${LENGTH}" -ge 300 ]] || return 1
}

function main_test() {
    local TESTS
    TESTS=$(declare -F | awk '$3 ~ /^test_/ { print $3 }')

    local TEST
    for TEST in ${TESTS}; do
        run_test "${TEST}"
    done

    if [[ -z "${SMOKE_BINARY}" ]]; then
        echo "Rendering with a real tf_plan_format skipped: TF_PLAN_FORMAT_ACTION_TEST_BINARY is not set"
    fi
    echo "${PASSED} passed, ${FAILED} failed"
    [[ "${FAILED}" -eq 0 ]]
}

main_test
