#!/usr/bin/env bash
set -euo pipefail

# Run the whole workflow on ONE machine, inside the container, with no scheduler.
#
# This is the no-SLURM path: a workstation, the dragen server, a cloud VM. The
# Snakemake driver runs in the image with `executor: local`, so every rule is a
# child process of that same driver, in that same container. Nothing is
# submitted anywhere.
#
# That is what makes this so much shorter than run_hpc3_container.sh. The whole
# apparatus over there -- the generated .container/bin/python shim,
# --shared-fs-usage minus software-deployment, --precommand, the bound-in slurm
# client -- exists solely to get a job that SLURM starts on some other node back
# inside this image. With no other node, none of it is needed.
#
# You are expected to already be on the machine you want to use; this script
# does not allocate anything. It measures the host and sizes Snakemake to it
# (see scripts/local_resources.sh).
#
# For HPC3, use run_hpc3_container.sh. For this path without Singularity, use
# run_local.sh.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

# shellcheck source=scripts/find_singularity.sh
source "$here/scripts/find_singularity.sh"
# shellcheck source=scripts/container_binds.sh
source "$here/scripts/container_binds.sh"
# shellcheck source=scripts/read_config_key.sh
source "$here/scripts/read_config_key.sh"
# shellcheck source=scripts/local_resources.sh
source "$here/scripts/local_resources.sh"

# Must precede load_dotenv.sh: that script pins SNAKEMAKE_PROFILE, defaulting to
# profiles/hpc3, and would otherwise hand the slurm profile to a host with no
# slurm on it.
export BCL_SNAKEMAKE_PROFILE="profiles/local"
# Secrets. Singularity passes the host environment through (no --cleanenv
# below), and with the local executor every rule inherits it directly from the
# driver, so sourcing here is enough for the whole DAG.
# shellcheck source=scripts/load_dotenv.sh
source "$here/scripts/load_dotenv.sh"

SINGULARITY="$(find_singularity)"

# Image: $BCL_CONVERT_SIF wins, else the `container_sif` config key.
SIF="${BCL_CONVERT_SIF:-$(read_config_key container_sif || true)}"
if [[ -z "$SIF" ]]; then
    echo "Error: no container image. Set container_sif in snakemake_config.yaml" >&2
    echo "or export BCL_CONVERT_SIF=/path/to/bcl_convert.sif" >&2
    exit 1
fi
if [[ ! -r "$SIF" ]]; then
    echo "Error: cannot read container image $SIF" >&2
    echo "If this is the lab copy, check you are in group ucightf: id | grep ucightf" >&2
    exit 1
fi

# bcl-convert writes here; see the comment on CONTAINER_LOG_BIND.
mkdir -p /tmp/bcl-convert-logs

# No sbatch is ever called, so the host slurm client stays out of the image.
export CONTAINER_SKIP_SLURM_BINDS=1
BINDS="$(container_binds_flat "$SINGULARITY")"

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

SNAKEMAKE_ARGS=(
    snakemake
    --profile profiles/local
    # Without this, snakemake auto-merges profiles/default (the dragen-server
    # profile) and its settings win over --profile.
    --workflow-profile none
    # The host budget. --local-cores matters even here: rules Snakemake treats
    # as local jobs are capped by it independently of --cores.
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

# shellcheck disable=SC2086  # $BINDS is a deliberately word-split flag list
exec "$SINGULARITY" exec --writable-tmpfs $BINDS \
    --pwd "$here" "$SIF" "${SNAKEMAKE_ARGS[@]}"
