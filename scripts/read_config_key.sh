#!/usr/bin/env bash
# Read a top-level scalar key out of the workflow's YAML config, using nothing
# but sed.
#
# The point of running everything in a container is that the host needs no
# python, no pixi and no yaml module. Anything that reads config *before* the
# container starts — the launcher picking an image, cron deciding whether a run
# is ready — therefore cannot use `python3 -c "import yaml"`.
#
# Scope is deliberately small: top-level `key: value` scalars only. Nested keys,
# lists and multi-line strings are not supported and never needed here.
#
# Usage:
#   source scripts/read_config_key.sh
#   value="$(read_config_key data_dir)"     # project config wins over base

read_config_key_from() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 1
    sed -n "s/^${key}:[[:space:]]*[\"']\{0,1\}\([^\"'#]*\)[\"']\{0,1\}[[:space:]]*\$/\1/p" "$file" \
        | sed 's/[[:space:]]*$//' \
        | grep -v '^$' \
        | tail -n 1
}

# Same precedence Snakemake applies: the per-run project config overrides the
# tracked base config.
read_config_key() {
    local key="$1" value
    value="$(read_config_key_from "$key" snakemake_config_project.yaml || true)"
    [[ -n "$value" ]] && { printf '%s\n' "$value"; return 0; }
    value="$(read_config_key_from "$key" snakemake_config.yaml || true)"
    [[ -n "$value" ]] && { printf '%s\n' "$value"; return 0; }
    return 1
}
