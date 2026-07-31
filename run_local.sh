#!/usr/bin/env bash
set -euo pipefail

# Single node, no scheduler, no container: the pixi env supplies every tool.
#
# A machine with no SLURM often has no Singularity either, so this is a real
# path here rather than the development-only fallback run_hpc3.sh is. The one
# thing it cannot supply is bcl-convert, which is an RPM baked into the image
# and not a pixi package -- so the bcl_convert rules need it already installed
# and on PATH. Everything downstream (flexbar, fqtk, fastp, seqkit, ...) comes
# from pixi. Use run_local_container.sh where Singularity exists.

# Must be exported before the pixi re-exec below: pixi runs
# scripts/load_dotenv.sh as an activation script, and that pins
# SNAKEMAKE_PROFILE to profiles/hpc3 unless told otherwise.
export BCL_SNAKEMAKE_PROFILE="profiles/local"

# Re-exec inside the pixi env if not already there. Without this, a stray conda
# env earlier on PATH can shadow pixi's snakemake and silently run against a
# different set of tools.
if [[ -z "${PIXI_ENVIRONMENT_NAME:-}" ]]; then
    here="$(cd "$(dirname "$0")" && pwd)"
    exec pixi run --manifest-path "$here/pixi.toml" bash "$0" "$@"
fi

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

# shellcheck source=scripts/local_resources.sh
source "$here/scripts/local_resources.sh"

mkdir -p /tmp/bcl-convert-logs

# Sets LOCAL_CORES, LOCAL_MEM_MB, LOCAL_SET_RESOURCES.
local_resources

DRY_RUN=0
PASSTHROUGH_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dryrun|--dry-run) DRY_RUN=1 ;;
        *) PASSTHROUGH_ARGS+=("$arg") ;;
    esac
done

# --workflow-profile none: without it snakemake auto-merges profiles/default
# (the dragen-server profile) and its settings win over --profile.
SNAKEMAKE_ARGS=(
    snakemake
    --profile profiles/local
    --workflow-profile none
    --cores "$LOCAL_CORES"
    --local-cores "$LOCAL_CORES"
    --resources "mem_mb=$LOCAL_MEM_MB"
)
if (( ${#LOCAL_SET_RESOURCES[@]} > 0 )); then
    SNAKEMAKE_ARGS+=("${LOCAL_SET_RESOURCES[@]}")
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
    SNAKEMAKE_ARGS+=(--dry-run)
fi
if [[ ${#PASSTHROUGH_ARGS[@]} -gt 0 ]]; then
    SNAKEMAKE_ARGS+=("${PASSTHROUGH_ARGS[@]}")
fi

exec "${SNAKEMAKE_ARGS[@]}"
