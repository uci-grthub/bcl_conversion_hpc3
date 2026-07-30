#!/bin/bash
# One-time per-run setup for HPC3. Run once after cloning into a run directory:
#   pixi run init
#
# Idempotent: safe to re-run. It:
#   1. creates snakemake_config_project.yaml from the base config (if missing),
#   2. prefills metadata / library_name / data_dir in that project config.
# Review the result and fill ~/.env (secrets) before running the workflow, if
# enable_nextcloud/SEND_EMAILS are turned on.
#
# Differences from the upstream (Nextcloud-staged) version:
#   * No sequencer / Nextcloud staging branching. BCL run folders live in a
#     single HPC3 staging path (default: /dfs3b/ucightf_lab/NSRaw).
#   * No ../SampleSheets copy step. The metadata .xlsx is expected to already
#     be in metadata/ (use whatever .xlsx is there).

set -euo pipefail

staging_dir="/dfs3b/ucightf_lab/NSRaw"
data_dir_override=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --staging-dir) staging_dir="$2"; shift 2 ;;
        --data-dir)    data_dir_override="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Use the .xlsx already present in metadata/ (excluding validation outputs).
metadata_file=$( { find metadata/ -maxdepth 1 -name "*.xlsx" ! -name "metadata_validation*" 2>/dev/null | head -1; } || true)

if [ ! -f snakemake_config_project.yaml ]; then
    cp snakemake_config.yaml snakemake_config_project.yaml
fi

if [ -n "$metadata_file" ]; then
    sed -i "s|^metadata:.*|metadata: \"$metadata_file\"|" snakemake_config_project.yaml
    echo "  metadata --> $metadata_file"

    library_name=$(basename "$metadata_file" .xlsx | grep -oE '[ix]R[0-9]+' || true)
    if [ -n "$library_name" ]; then
        sed -i "s|^library_name:.*|library_name: \"$library_name\"|" snakemake_config_project.yaml
        echo "  library_name --> $library_name"
    else
        echo "  WARNING: Could not infer library_name from $metadata_file — set it manually."
    fi
else
    echo "  WARNING: No .xlsx found in metadata/ — set metadata and library_name manually."
fi

# Determine the BCL run folder (data_dir).
if [ -n "$data_dir_override" ]; then
    data_dir="$data_dir_override"
else
    data_dir=$( { find "$staging_dir" -maxdepth 1 -mindepth 1 -type d -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-; } || true)
fi
if [ -n "$data_dir" ]; then
    sed -i "s|^data_dir:.*|data_dir: \"$data_dir\"|" snakemake_config_project.yaml
    echo "  data_dir --> $data_dir"
else
    echo "  WARNING: Could not find a run dir in $staging_dir — set data_dir manually."
fi

echo "Ready: snakemake_config_project.yaml created/updated. Review it, then run \`pixi run validate\`."
