#!/usr/bin/env bash
set -euo pipefail

# Run one command inside the workflow container.
#
# For the one-off tasks that are not a Snakemake run but still need the image's
# python, snakemake or graphviz -- the container equivalents of the pixi tasks
# that are not `pixi run all`:
#
#   bash scripts/container_exec.sh python run_validation.py        # pixi run validate
#   bash scripts/container_exec.sh snakemake --rulegraph > rg.dot  # pixi run rulegraph
#   bash scripts/container_exec.sh bcl-convert --version
#
# `pixi run init` needs none of this: scripts/init_run.sh is plain bash.
#
# For an actual workflow run use run_hpc3_container.sh instead -- it adds the
# SLURM-submission flags (--shared-fs-usage, --precommand) and the compute-node
# python shim, none of which apply to a single foreground command.
#
# The image, binds and singularity binary are resolved exactly as the launcher
# resolves them, by sourcing the same three helpers, so the two can never
# disagree about which image or which mounts.
#
# One deliberate difference from `pixi run`: SNAKEMAKE_PROFILE is NOT set here.
# pixi's [activation.env] sets it, which would silently give a foreground
# `snakemake` here the slurm executor and start submitting jobs. Pass --profile
# explicitly when that is what you want.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -eq 0 ]]; then
    echo "Usage: bash scripts/container_exec.sh <command> [args...]" >&2
    echo "Example: bash scripts/container_exec.sh python run_validation.py" >&2
    exit 2
fi

# shellcheck source=scripts/find_singularity.sh
source "$here/scripts/find_singularity.sh"
# shellcheck source=scripts/container_binds.sh
source "$here/scripts/container_binds.sh"
# shellcheck source=scripts/read_config_key.sh
source "$here/scripts/read_config_key.sh"
# Matches the pixi [activation] hook, so a command run through here sees the
# same secrets it would have seen under `pixi run`.
# shellcheck source=scripts/load_dotenv.sh
source "$here/scripts/load_dotenv.sh"

SINGULARITY="$(find_singularity)"

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

# bcl-convert aborts if /var/log/bcl-convert is read-only, and singularity
# refuses to start at all when a bind source is missing. Cheap either way.
mkdir -p "$CONTAINER_LOG_DIR"

BINDS="$(container_binds_flat "$SINGULARITY")"

# --pwd "$PWD", not the repo root: this is a general-purpose exec and the caller
# may well be in a subdirectory. Anything under the data binds stays visible.
# shellcheck disable=SC2086  # $BINDS is a deliberately word-split flag list
exec "$SINGULARITY" exec --writable-tmpfs $BINDS \
    --pwd "$PWD" "$SIF" "$@"
