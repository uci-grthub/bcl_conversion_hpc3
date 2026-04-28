#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${BCL_CONVERT_SIF:-/dfs9/ucightf-lab/kstachel/containers/bcl_convert.sif}"
BCL_LOG_DIR="${TMPDIR:-/tmp}/bcl-convert-logs"
mkdir -p "$BCL_LOG_DIR"

# Singularity ignores the container's ENV PATH directive — inject it explicitly
# so that find, xargs, md5sum, wc, sort, etc. from the pixi env are available.
PIXI_BIN=/app/.pixi/envs/default/bin

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

singularity exec \
    --bind /dfs9,"$BCL_LOG_DIR":/var/log/bcl-convert \
    --env "PATH=${PIXI_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$CONTAINER" \
    "${SNAKEMAKE_ARGS[@]}"
