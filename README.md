# TF Plan Format Action

[![CI](https://github.com/ovsds/tf-plan-format-action/workflows/Check%20PR/badge.svg)](https://github.com/ovsds/tf-plan-format-action/actions?query=workflow%3A%22%22Check+PR%22%22)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-TF%20Plan%20Format-blue.svg)](https://github.com/marketplace/actions/tf-plan-format)

TF Plan Format Action

## Usage

### Example

```yaml
jobs:
  tf-plan-format:
    steps:
      - name: TF Plan Format
        id: tf-plan-format
        uses: ovsds/tf-plan-format-action@v1
```

### Action Inputs

```yaml
inputs:
  placeholder:
    description: |
      Placeholder input to be replaced by real inputs
    required: true
    default: "placeholder"
```

### Action Outputs

```yaml
outputs:
  placeholder:
    description: |
      Placeholder output to be replaced by real outputs
    value: ${{steps.placeholder.outputs.placeholder }}
```

## Development

### Global dependencies

- [mise](https://mise.jdx.dev/installing-mise.html), activated in the shell (`eval "$(mise activate zsh)"`)

All other tools are pinned in [mise.toml](mise.toml).

### mise tasks

For all commands see [mise.toml](mise.toml) or `mise tasks ls`.

## License

[MIT](LICENSE)
