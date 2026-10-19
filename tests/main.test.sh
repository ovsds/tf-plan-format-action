#!/bin/bash

# Tests src/main.sh with a fake curl serving a local release: real downloads are left to the e2e workflow.
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

    export INPUT_PLAN_FILES="plan.json"
    export INPUT_PLAN_FILES_SEPARATOR=$'\n'
    export INPUT_VERSION="0.1.0"
    export INPUT_RENDERED_PLAN_PATH=""
    export RUNNER_OS="Linux"
    export RUNNER_ARCH="X64"
}

function get_output() {
    local KEY=$1
    sed -n "/^${KEY}<<EOF_[0-9]*$/,/^EOF_[0-9]*$/{/^${KEY}<<EOF_/d;/^EOF_[0-9]*$/d;p;}" "${GITHUB_OUTPUT}"
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

# A release of a stub binary in ${TEST_DIR}/release/<version>, with its checksums.txt
function prepare_release() {
    local VERSION=$1

    local DIR="${TEST_DIR}/release/${VERSION}"
    local ASSET="tf_plan_format-${VERSION}-linux-amd64.tar.gz"
    mkdir -p "${DIR}/content"
    write_stub_binary "${DIR}/content/tf_plan_format" 0
    tar -czf "${DIR}/${ASSET}" -C "${DIR}/content" tf_plan_format
    local SUM
    SUM=$(sha256 "${DIR}/${ASSET}")
    echo "${SUM}  ${ASSET}" > "${DIR}/checksums.txt"
}

# Stands in for curl on PATH: .../releases/download/<version>/<name> serves ${TEST_DIR}/release/<version>/<name>,
# anything else fails like curl --fail on a 404
function write_fake_curl() {
    mkdir -p "${TEST_DIR}/bin"
    cat > "${TEST_DIR}/bin/curl" << EOF
#!/bin/bash
OUTPUT=""
URL=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --output) OUTPUT=\$2; shift ;;
        --retry) shift ;;
        -*) ;;
        *) URL=\$1 ;;
    esac
    shift
done
echo "\${URL}" >> "${TEST_DIR}/curl_urls"
FILE="${TEST_DIR}/release/\${URL#*/releases/download/}"
if [[ "\${URL}" != */releases/download/* || ! -f "\${FILE}" ]]; then
    echo "curl: (22) 404" >&2
    exit 22
fi
cp "\${FILE}" "\${OUTPUT}"
EOF
    chmod +x "${TEST_DIR}/bin/curl"
    export PATH="${TEST_DIR}/bin:${PATH}"
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

function test_resolve_binary_installs_version() {
    prepare_release "0.1.0"
    write_fake_curl

    resolve_binary
    assert_equals "${RUNNER_TEMP}/tf-plan-format/0.1.0/tf_plan_format" "${BINARY}"
    [[ -x "${BINARY}" ]] || return 1
}

function test_resolve_binary_reuses_installed_version() {
    write_fake_curl
    mkdir -p "${RUNNER_TEMP}/tf-plan-format/0.1.0"
    write_stub_binary "${RUNNER_TEMP}/tf-plan-format/0.1.0/tf_plan_format" 0

    resolve_binary
    assert_equals "${RUNNER_TEMP}/tf-plan-format/0.1.0/tf_plan_format" "${BINARY}"
    [[ ! -e "${TEST_DIR}/curl_urls" ]] || return 1
}

function test_resolve_binary_fails_on_missing_release() {
    write_fake_curl
    INPUT_VERSION="9.9.9"

    assert_fails_with "Failed to download https://github.com/ovsds/tf-plan-format/releases/download/9.9.9/tf_plan_format-9.9.9-linux-amd64.tar.gz" \
        resolve_binary
}

function test_resolve_binary_rejects_checksum_mismatch() {
    prepare_release "0.1.0"
    write_fake_curl
    echo "tampered" >> "${TEST_DIR}/release/0.1.0/tf_plan_format-0.1.0-linux-amd64.tar.gz"

    assert_fails_with "Checksum mismatch for tf_plan_format-0.1.0-linux-amd64.tar.gz" resolve_binary
}

function test_resolve_binary_rejects_missing_checksum() {
    prepare_release "0.1.0"
    write_fake_curl
    : > "${TEST_DIR}/release/0.1.0/checksums.txt"

    assert_fails_with "expected no checksums.txt entry" resolve_binary
}

function test_resolve_binary_fails_on_archive_without_binary() {
    prepare_release "0.1.0"
    write_fake_curl
    local DIR="${TEST_DIR}/release/0.1.0"
    local ASSET="tf_plan_format-0.1.0-linux-amd64.tar.gz"
    tar -czf "${DIR}/${ASSET}" -C "${DIR}" checksums.txt
    local SUM
    SUM=$(sha256 "${DIR}/${ASSET}")
    echo "${SUM}  ${ASSET}" > "${DIR}/checksums.txt"

    assert_fails_with "Failed to unpack tf_plan_format from ${ASSET}" resolve_binary
}

function test_build_cli_args_splits_by_newline() {
    INPUT_PLAN_FILES=$'  plans/a.json  \n\n\tplans/*/plan.json\n'

    build_cli_args
    local ACTUAL
    ACTUAL=$(join_cli_args)
    assert_equals "github|--file|plans/a.json|--file|plans/*/plan.json" "${ACTUAL}"
}

function test_build_cli_args_splits_by_separator() {
    INPUT_PLAN_FILES="plans/a.json, plans/b.json,,plans/*/plan.json"
    INPUT_PLAN_FILES_SEPARATOR=","

    build_cli_args
    local ACTUAL
    ACTUAL=$(join_cli_args)
    assert_equals "github|--file|plans/a.json|--file|plans/b.json|--file|plans/*/plan.json" "${ACTUAL}"
}

function test_build_cli_args_splits_by_multi_character_separator() {
    INPUT_PLAN_FILES="a.json::b.json"
    INPUT_PLAN_FILES_SEPARATOR="::"

    build_cli_args
    local ACTUAL
    ACTUAL=$(join_cli_args)
    assert_equals "github|--file|a.json|--file|b.json" "${ACTUAL}"
}

function test_main_returns_rendered_plan() {
    write_stub_binary "${TEST_DIR}/tf_plan_format" 0
    export TF_PLAN_FORMAT_ACTION_TEST_BINARY="${TEST_DIR}/tf_plan_format"
    INPUT_PLAN_FILES=$'a.json\nb.json'

    main

    local RENDERED_PLAN
    RENDERED_PLAN=$(get_output "rendered-plan")
    assert_equals $'github\n--file\na.json\n--file\nb.json' "${RENDERED_PLAN}"
}

function test_main_writes_rendered_plan_to_path() {
    write_stub_binary "${TEST_DIR}/tf_plan_format" 0
    export TF_PLAN_FORMAT_ACTION_TEST_BINARY="${TEST_DIR}/tf_plan_format"
    INPUT_RENDERED_PLAN_PATH="${TEST_DIR}/out/plan.md"

    main

    local RENDERED_PLAN
    RENDERED_PLAN=$(cat "${INPUT_RENDERED_PLAN_PATH}")
    assert_equals $'github\n--file\nplan.json' "${RENDERED_PLAN}"
    [[ ! -s "${GITHUB_OUTPUT}" ]] || return 1
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
    INPUT_PLAN_FILES=$'tests/plans/create/opentofu.tfplan.json\ntests/plans/u*/opentofu.tfplan.json\ntests/plans/outputs/opentofu.tfplan.json'

    (cd "${ROOT_DIR}" && main)

    local RENDERED_PLAN
    RENDERED_PLAN=$(get_output "rendered-plan")
    assert_equals "<details>" "${RENDERED_PLAN:0:9}"
    assert_contains "${RENDERED_PLAN}" "terraform_data.foo-bar"
    assert_contains "${RENDERED_PLAN}" "create - Plan: 1 to add, 0 to change, 0 to destroy"
    assert_contains "${RENDERED_PLAN}" "update - Plan: 0 to add, 1 to change, 0 to destroy"
    assert_contains "${RENDERED_PLAN}" "Outputs"
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
