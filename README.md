# TF Plan Format Action

[![CI](https://github.com/ovsds/tf-plan-format-action/workflows/Check%20PR/badge.svg)](https://github.com/ovsds/tf-plan-format-action/actions?query=workflow%3A%22%22Check+PR%22%22)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-TF%20Plan%20Format-blue.svg)](https://github.com/marketplace/actions/tf-plan-format)

Renders Terraform and OpenTofu plans with [tf-plan-format](https://github.com/ovsds/tf-plan-format) and posts them as a pull request comment, updating the same comment on every run.

The action downloads the `tf_plan_format` release for the runner (Linux or macOS, X64 or ARM64), verifies its SHA-256 checksum and unpacks it into `$RUNNER_TEMP`; `latest` is the highest `X.Y.Z` version among the 10 newest stable releases that have the runner's archive and `checksums.txt` fully uploaded. It renders the plan JSON files into a markdown file in `$RUNNER_TEMP`: a hidden `<!-- tf-plan-format-action:<comment-key> -->` marker, a `## <title>` heading and the output of `tf_plan_format github`, all within `max-length` bytes. Then [create-or-update-unique-comment-action](https://github.com/ovsds/create-or-update-unique-comment-action) creates the comment, or updates the one that already has the marker.

## Usage

### Example

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
          files: ${{ runner.temp }}/plan.json
```

Several jobs or steps keep separate comments when each sets its own `comment-key`. With `comment: false` the action only renders, and the markdown can go elsewhere, for example to the job summary:

```yaml
- name: TF Plan Format
  id: tf-plan-format
  uses: ovsds/tf-plan-format-action@v1
  with:
    files: |
      ${{ runner.temp }}/plans/*/plan.json
    comment: false

- name: Job summary
  run: |
    cat "${MARKDOWN_PATH}" >> "${GITHUB_STEP_SUMMARY}"
  env:
    MARKDOWN_PATH: ${{ steps.tf-plan-format.outputs.markdown-path }}
```

On pull requests from forks the default `GITHUB_TOKEN` is read-only, so the comment step fails. Set `comment: false` for them, for example `comment: ${{ github.event.pull_request.head.repo.full_name == github.repository }}`, and render elsewhere, like the job summary above from `markdown-path`. A `pull_request_target` workflow gets a writable token, but it runs with the base repository's secrets and permissions: planning code from a fork there needs great care.

With a personal access token or a GitHub App token in `token`, set `comment-author` to the token's user, like `my-app[bot]` for an app: the comment to update is looked up by its author, and with the default `github-actions[bot]` every run would post a new comment.

### Security

The plan file and its JSON hold sensitive values in clear text, whatever the configuration marks as sensitive. Write them to `$RUNNER_TEMP`, never commit them, upload them as artifacts or cache them. The rendered comment masks sensitive values, but it is public to everyone who can read the pull request: review what the plan shows before using the action on a public repository.

### Requirements

The runner needs `bash`, `curl`, `tar`, `jq` and `sha256sum` or `shasum`, all preinstalled on GitHub-hosted runners. Releases of tf-plan-format exist for Linux and macOS on X64 and ARM64; other runners fail.

### Action Inputs

```yaml
inputs:
  files:
    description: |
      Newline-separated plan JSON paths or globs (the output of `show -json`)
    required: true
  version:
    description: |
      tf-plan-format release tag without the v prefix, like 0.1.0, or latest
    required: true
    default: "latest"
  max-length:
    description: |
      Maximum length of the whole rendered markdown in bytes, the marker and the heading included, under GitHub's 65536-character comment limit; the plans get what the marker and the heading leave
    required: true
    default: "65000"
  changed-values:
    description: |
      Also list the attributes that did not change in updates and replacements
    required: true
    default: "false"
  show-no-op:
    description: |
      Render no-op changes
    required: true
    default: "false"
  show-read:
    description: |
      Render data source reads
    required: true
    default: "false"
  title:
    description: |
      Heading of the rendered markdown
    required: true
    default: "Plan"
  comment:
    description: |
      Post or update the pull request comment; false only renders the markdown
    required: true
    default: "true"
  comment-key:
    description: |
      Key of the hidden comment marker; distinct keys keep separate comments
    required: true
    default: "default"
  issue-number:
    description: |
      Issue or pull request number to comment on, the pull request of the event by default
    required: false
    default: ${{ github.event.pull_request.number }}
  token:
    description: |
      GitHub token used to resolve the latest release and to post the comment
    required: true
    default: ${{ github.token }}
  comment-author:
    description: |
      Login of the comment author whose comment is updated; set it to the token's user when token is not the workflow's GITHUB_TOKEN
    required: true
    default: "github-actions[bot]"
```

### Action Outputs

```yaml
outputs:
  markdown-path:
    description: |
      Path of the rendered markdown file
    value: ${{ steps.run.outputs.markdown-path }}
  comment-id:
    description: |
      ID of the created or updated comment, empty when comment is false
    value: ${{ steps.comment.outputs.comment-id }}
```

## Development

### Global dependencies

- [mise](https://mise.jdx.dev/installing-mise.html), activated in the shell (`eval "$(mise activate zsh)"`)

All other tools are pinned in [mise.toml](mise.toml).

### mise tasks

For all commands see [mise.toml](mise.toml) or `mise tasks ls`.

## License

[MIT](LICENSE)
