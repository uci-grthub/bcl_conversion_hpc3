#!/usr/bin/env bash
set -euo pipefail

# Re-exec inside the pixi env if not already there. Without this, a stray
# conda env earlier on PATH (e.g. snakemake_dfs) can shadow pixi's snakemake
# and silently run without the slurm executor plugin, breaking
# --profile profiles/hpc3 with "invalid choice: 'slurm'".
if [[ -z "${PIXI_ENVIRONMENT_NAME:-}" ]]; then
    here="$(cd "$(dirname "$0")" && pwd)"
    exec pixi run --manifest-path "$here/pixi.toml" bash "$0" "$@"
fi

mkdir -p /tmp/bcl-convert-logs

DRY_RUN=0
PASSTHROUGH_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dryrun|--dry-run)
            DRY_RUN=1
            ;;
        *)
            PASSTHROUGH_ARGS+=("$arg")
            ;;
    esac
done

SNAKEMAKE_ARGS=(snakemake --profile profiles/hpc3)
if [[ "$DRY_RUN" -eq 1 ]]; then
    SNAKEMAKE_ARGS+=(--dry-run)
fi
SNAKEMAKE_ARGS+=("${PASSTHROUGH_ARGS[@]}")

"${SNAKEMAKE_ARGS[@]}"
