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

# --workflow-profile none: without this, snakemake auto-merges profiles/default
# (the dragen-server profile) and its settings win over --profile, silently
# reimposing serial_operation=1 and blocking hpc3 job parallelism.
SNAKEMAKE_ARGS=(snakemake --profile profiles/hpc3 --workflow-profile none)

# The profile pins slurm_account to the lab's usual account. An operator on a
# different account exports SLURM_ACCOUNT instead of editing a tracked file.
# List yours with: sacctmgr -nP show assoc user=$USER format=Account
#
# --default-resources on the command line REPLACES the profile's whole
# default-resources block rather than merging into it, so the other three
# defaults have to be repeated here or they silently revert to snakemake's
# built-ins (no partition, dynamic mem_mb, no runtime).
if [[ -n "${SLURM_ACCOUNT:-}" ]]; then
    SNAKEMAKE_ARGS+=(--default-resources
        "slurm_account=$SLURM_ACCOUNT"
        "slurm_partition=standard"
        "mem_mb=8000"
        "runtime=60")
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    SNAKEMAKE_ARGS+=(--dry-run)
fi
SNAKEMAKE_ARGS+=("${PASSTHROUGH_ARGS[@]}")

"${SNAKEMAKE_ARGS[@]}"
