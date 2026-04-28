#!/usr/bin/env bash
set -euo pipefail

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
