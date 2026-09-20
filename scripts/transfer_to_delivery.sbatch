#!/bin/bash
#SBATCH --job-name=xfer_delivery
#SBATCH --partition=standard
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=24:00:00
#SBATCH --output=logs/transfer_to_delivery_%j.log
#
# Push a finished conversion run to the delivery host as a batch job.
#
# A multi-TB rsync does not belong in an interactive allocation: it outlives the
# terminal it was started from, and nohup/setsid do not detach it from the slurm
# cgroup, so it dies with that allocation's time limit or scancel anyway.
#
# Submit (the account is per-operator and deliberately absent from this file --
# see scripts/require_slurm_account.sh):
#
#   sbatch --account="$SLURM_ACCOUNT" scripts/transfer_to_delivery.sbatch \
#       kstachel@128.195.12.34:/mnt/jbod_localdisk/nextshare/bcl_convert/NovaSeqX/xR115/
#
# Submit from the run directory: the job takes its root from $SLURM_SUBMIT_DIR, and
# --output=logs/... is relative to it. Pass --dry-run before the destination to
# exercise the whole path as a job without transferring anything.
#
# Then poll with squeue/sacct, not ps:
#
#   squeue -j <jobid> -o "%.10i %.9P %.10M %.10l %.10L"
#   tail -f logs/transfer_to_delivery_<jobid>.log
#
# --partition=standard, not free: rsync resumes cleanly (-P keeps partial files)
# but has no automatic restart, so a preemption would leave the transfer needing a
# manual resubmit. --time=24:00:00 against a measured 110 MiB/s to the delivery
# host: 4.28TiB lands in ~11.3h, so this is 2x headroom and still covers a
# sustained rate as low as ~52 MiB/s.
#
# Rerunnable: rsync skips what already matches, so resubmitting after a timeout or
# a failure continues rather than restarting. Verify with --dry-run first.

set -euo pipefail

DRY_RUN_ARG=()
DEST=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN_ARG=(--dry-run) ;;
        *)         DEST="$arg" ;;
    esac
done

if [[ -z "$DEST" ]]; then
    echo "ERROR: no destination given." >&2
    echo "Usage: sbatch --account=\"\$SLURM_ACCOUNT\" $0 [--dry-run] <user@host:/path/to/RUN/>" >&2
    exit 1
fi

# NOT ${BASH_SOURCE[0]}: slurm runs a COPY of this file from its spool directory
# (/export/spool/slurm/slurmd.spool/job<id>/slurm_script), so resolving the run
# directory from the script's own path lands in a read-only system directory.
# $SLURM_SUBMIT_DIR is where sbatch was invoked, which is also the job's cwd.
ROOT_DIR="${SLURM_SUBMIT_DIR:-$PWD}"
cd "$ROOT_DIR"

if [[ ! -f "scripts/transfer_to_delivery.sh" ]]; then
    echo "ERROR: $ROOT_DIR is not a run directory (no scripts/transfer_to_delivery.sh)." >&2
    echo "Submit from the run directory you want to transfer." >&2
    exit 1
fi

# The account guard that require_slurm_account.sh applies at submit time cannot run
# here -- by now slurm has already chosen one. Catch the failure it exists to
# prevent: an unset SLURM_ACCOUNT means slurm charged the user's default
# association, which is usually their personal account, and that is silent.
if [[ -n "${SLURM_JOB_ACCOUNT:-}" && "${SLURM_JOB_ACCOUNT}" == "${USER}" ]]; then
    echo "ERROR: this job is charged to account '${SLURM_JOB_ACCOUNT}', which is your" >&2
    echo "personal default, not a lab account. Resubmit with:" >&2
    echo "    sbatch --account=\"\$SLURM_ACCOUNT\" $0 $DEST" >&2
    exit 1
fi

echo "Job:         ${SLURM_JOB_ID:-<no job>} on $(hostname)"
echo "Account:     ${SLURM_JOB_ACCOUNT:-<unknown>}"
echo "Started:     $(date)"
echo ""

mkdir -p logs

# Reuse the one place the flags live, rather than restating them. --lan adds -W:
# delta encoding is wasted work on already-compressed FASTQs over a LAN.
bash scripts/transfer_to_delivery.sh --lan "${DRY_RUN_ARG[@]}" "$DEST"

echo ""
echo "Finished:    $(date)"
