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

    # Plan files are relative to the working directory or absolute, often in $RUNNER_TEMP: both are mounted as is,
    # read-only and without network, as the plans hold sensitive values in clear text
    if ! docker run --rm --network none \
        --volume "${PWD}:${PWD}:ro" --volume "${RUNNER_TEMP}:${RUNNER_TEMP}:ro" --workdir "${PWD}" \
        "ghcr.io/ovsds/tf-plan-format:${INPUT_VERSION}" "${ARGS[@]}" > "${RENDERED_PLAN_PATH}"; then
        print_error "tf_plan_format failed to render the plans"
        exit 1
    fi

    local RENDERED_PLAN
    RENDERED_PLAN=$(cat "${RENDERED_PLAN_PATH}")
    set_output "rendered-plan" "${RENDERED_PLAN}"
    set_output "rendered-plan-path" "${RENDERED_PLAN_PATH}"
}

main "$@"
