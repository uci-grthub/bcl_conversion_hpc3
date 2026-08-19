#!/usr/bin/env bash
#SBATCH --job-name=xR106-convert
#SBATCH --partition=standard
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=2-00:00:00
#SBATCH --output=logs/slurm/driver-%j.out
#SBATCH --error=logs/slurm/driver-%j.out

# Submit the conversion workflow as its own batch job:
#
#   sbatch --account="$SLURM_ACCOUNT" scripts/run_workflow_hpc3.sbatch
#
# No --account in the header on purpose. It is per-operator and a value
# committed to a tracked file is wrong for everyone but its author -- the same
# reason profiles/hpc3/config.yaml has none. Pass it at submit time from
# $SLURM_ACCOUNT (set it in ~/.env); the check below refuses to start without
# one, because slurm would otherwise charge the submitter's default
# association.
#
# --partition=standard, not free: this is the long-lived Snakemake driver. It
# is not checkpointed, and a preempted driver abandons every bcl-convert job it
# has in flight.
#
# The driver only submits and waits, so 4 CPUs / 16G is ample -- every real
# rule runs in its own SLURM job.

set -euo pipefail

# Not $BASH_SOURCE: sbatch copies the script into its spool
# (/export/spool/slurm/slurmd.spool/job<id>/slurm_script), so inside the job
# $BASH_SOURCE points at that copy and every repo-relative path resolves to a
# spool directory that contains nothing. $SLURM_SUBMIT_DIR is the directory
# sbatch was invoked from, which is the repo -- verified below rather than
# assumed.
here="${SLURM_SUBMIT_DIR:-$PWD}"
if [[ ! -f "$here/run_hpc3_container.sh" ]]; then
    echo "Error: $here is not the repo root (no run_hpc3_container.sh)." >&2
    echo "Submit from the repo: cd <repo> && sbatch --account=\"\$SLURM_ACCOUNT\" scripts/run_workflow_hpc3.sbatch" >&2
    exit 1
fi
cd "$here"

# shellcheck source=scripts/load_dotenv.sh
source "$here/scripts/load_dotenv.sh"

if [[ -z "${SLURM_ACCOUNT:-}" ]]; then
    echo "Error: SLURM_ACCOUNT is unset. Set it in ~/.env and resubmit with" >&2
    echo "  sbatch --account=\"\$SLURM_ACCOUNT\" scripts/run_workflow_hpc3.sbatch" >&2
    exit 1
fi

echo "driver job ${SLURM_JOB_ID:-?} on $(hostname), account ${SLURM_ACCOUNT}"
echo "started $(date -Is)"

bash run_hpc3_container.sh

echo "finished $(date -Is)"
