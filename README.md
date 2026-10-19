# TF Plan Format Action

[![CI](https://github.com/ovsds/tf-plan-format-action/workflows/Check%20PR/badge.svg)](https://github.com/ovsds/tf-plan-format-action/actions?query=workflow%3A%22%22Check+PR%22%22)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-TF%20Plan%20Format-blue.svg)](https://github.com/marketplace/actions/tf-plan-format)

Renders Terraform and OpenTofu plans into GitHub markdown with [tf-plan-format](https://github.com/ovsds/tf-plan-format) and returns it, both as the `rendered-plan` output and as a file at `rendered-plan-path`.

The action is a thin layer over the `tf_plan_format` binary: it installs the `version` release into `$RUNNER_TEMP` with the [setup.sh](https://github.com/ovsds/tf-plan-format/blob/main/setup.sh) from that release's tag, which verifies the archive's checksum, and runs `tf_plan_format github` with a `--file` for each of the plan files. Since tf-plan-format 0.2.0, the first version the action supports, the rendered plan starts with a hidden `<!-- tf-plan-format -->` line, so a comment holding it can be found and updated. It posts nothing: where the markdown goes is the caller's choice.

## Usage

### Example

Render the plan and keep it in one pull request comment with [create-or-update-unique-comment-action](https://github.com/ovsds/create-or-update-unique-comment-action):

```yaml
on: pull_request

permissions:
  contents: read
  pull-requests: write

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Setup OpenTofu
        uses: opentofu/setup-opentofu@v1
        with:
          tofu_wrapper: false

      - name: Plan
        run: |
          tofu init -input=false
          tofu plan -input=false -out="${RUNNER_TEMP}/plan.tfplan"
          tofu show -json "${RUNNER_TEMP}/plan.tfplan" > "${RUNNER_TEMP}/plan.json"

      - name: TF Plan Format
        id: tf-plan-format
        uses: ovsds/tf-plan-format-action@v1
        with:
          plan-files: ${{ runner.temp }}/plan.json

      - name: Comment
        uses: ovsds/create-or-update-unique-comment-action@v1
        with:
          issue-number: ${{ github.event.pull_request.number }}
          body-path: ${{ steps.tf-plan-format.outputs.rendered-plan-path }}
          unique-body-includes: "<!-- tf-plan-format -->"
```

Plan files are separated by newlines, or by `plan-files-separator`, and may be globs:

```yaml
- name: TF Plan Format
  id: tf-plan-format
  uses: ovsds/tf-plan-format-action@v1
  with:
    plan-files: "plans/staging/plan.json,plans/production/*.json"
    plan-files-separator: ","

- name: Job summary
  run: echo "${RENDERED_PLAN}" >> "${GITHUB_STEP_SUMMARY}"
  env:
    RENDERED_PLAN: ${{ steps.tf-plan-format.outputs.rendered-plan }}
```

Large plans are better read from the `rendered-plan-path` file than passed on through the `rendered-plan` output. The rendered plan is not capped, while GitHub comments stop at 65536 characters.

### Security

The plan file and its JSON hold sensitive values in clear text, whatever the configuration marks as sensitive. Write them to `$RUNNER_TEMP`, never commit them, upload them as artifacts or cache them. The rendered markdown masks sensitive values, but wherever it is posted, everyone who can read it sees the rest of the plan: review what the plan shows before posting it on a public repository.

### Requirements

The runner needs `bash`, `curl` and `tar`, preinstalled on GitHub-hosted runners. Releases of tf-plan-format exist for Linux and macOS on X64 and ARM64; the Linux builds need glibc, so musl-based containers like Alpine are not supported.

### Action Inputs

```yaml
inputs:
  plan-files:
    description: |
      Plan JSON paths or globs (the output of `show -json`), separated by `plan-files-separator`
    required: true

  plan-files-separator:
    description: |
      Separator to split plan files
    required: true
    default: "\n"

  version:
    description: |
      tf-plan-format version, a release tag from 0.2.0 on
    required: true
    default: "0.2.0"
```

### Action Outputs

```yaml
outputs:
  rendered-plan:
    description: |
      Rendered plan in GitHub markdown
    value: ${{ steps.run.outputs.rendered-plan }}

  rendered-plan-path:
    description: |
      Path of a file in `$RUNNER_TEMP` holding the rendered plan
    value: ${{ steps.run.outputs.rendered-plan-path }}
```

## Development

### Global dependencies

- [mise](https://mise.jdx.dev/installing-mise.html), activated in the shell (`eval "$(mise activate zsh)"`)

All other tools are pinned in [mise.toml](mise.toml).

### mise tasks

For all commands see [mise.toml](mise.toml) or `mise tasks ls`.

## License

[MIT](LICENSE)
