#!/bin/bash
set -euo pipefail

function print_info() {
    local MESSAGE=$1
    echo "INFO: ${MESSAGE}"
}

function print_error() {
    local MESSAGE=$1
    echo "ERROR:: ${MESSAGE}"
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

function main() {
    INPUT_PLAN_FILES=${INPUT_PLAN_FILES:?"INPUT_PLAN_FILES is not set"}
    INPUT_PLAN_FILES_SEPARATOR=${INPUT_PLAN_FILES_SEPARATOR:?"INPUT_PLAN_FILES_SEPARATOR is not set"}
    INPUT_VERSION=${INPUT_VERSION:?"INPUT_VERSION is not set"}
    RUNNER_TEMP=${RUNNER_TEMP:?"RUNNER_TEMP is not set"}

    local ARGS=(github)
    local FILE
    local REST="${INPUT_PLAN_FILES}${INPUT_PLAN_FILES_SEPARATOR}"
    while [[ -n "${REST}" ]]; do
        FILE=${REST%%"${INPUT_PLAN_FILES_SEPARATOR}"*}
        REST=${REST#*"${INPUT_PLAN_FILES_SEPARATOR}"}
        if [[ -n "${FILE}" ]]; then
            ARGS+=(--file "${FILE}")
        fi
    done

    local RENDERED_PLAN_PATH
    RENDERED_PLAN_PATH="$(mktemp -d "${RUNNER_TEMP}/tf-plan-format-action.XXXXXX")/rendered-plan.md"

    local INSTALL_DIR="${RUNNER_TEMP}/tf-plan-format/${INPUT_VERSION}"
    if [[ ! -x "${INSTALL_DIR}/tf_plan_format" ]]; then
        # The script from the release's own tag, so it matches the assets it installs
        if ! curl --fail --silent --show-error --location --retry 3 \
            "https://raw.githubusercontent.com/ovsds/tf-plan-format/${INPUT_VERSION}/setup.sh" |
            bash -s -- "${INPUT_VERSION}" "${INSTALL_DIR}"; then
            print_error "Failed to install tf-plan-format ${INPUT_VERSION}, see the error above; versions before 0.2.0 have no setup.sh"
            exit 1
        fi
    fi

    if ! "${INSTALL_DIR}/tf_plan_format" "${ARGS[@]}" > "${RENDERED_PLAN_PATH}"; then
        print_error "tf_plan_format failed to render the plans"
        exit 1
    fi

    local RENDERED_PLAN
    RENDERED_PLAN=$(cat "${RENDERED_PLAN_PATH}")
    set_output "rendered-plan" "${RENDERED_PLAN}"
    set_output "rendered-plan-path" "${RENDERED_PLAN_PATH}"
}

main "$@"
