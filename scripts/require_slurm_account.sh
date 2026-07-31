# shellcheck shell=bash
#
# Resolve the slurm account for this operator and build the --default-resources
# override that carries it.
#
# The account is deliberately NOT in profiles/hpc3/config.yaml: it is per-person,
# and a value committed to a tracked file is wrong for everyone but its author.
#
# It also cannot simply be left out. snakemake-executor-plugin-slurm's account
# auto-guess is broken on this cluster -- it calls sacct with a flag combination
# sacct rejects ("invalid option -- '1'") -- so it falls back to submitting with
# no --account at all. Slurm then charges the user's DEFAULT association, which
# is usually their personal account rather than the lab's:
#
#     $ sacctmgr -nP show user $USER format=User,DefaultAccount
#     kstachel|kstachel
#
# That failure is silent: jobs run, on the wrong account. So refuse to submit
# instead, and make the operator say which account they mean.
#
# Sourced by run_hpc3.sh and run_hpc3_container.sh, both of which load ~/.env
# first, so `SLURM_ACCOUNT=...` in ~/.env is the intended place to set this once.
# Sets: SLURM_ACCOUNT_ARGS (array).

require_slurm_account() {
    if [[ -z "${SLURM_ACCOUNT:-}" ]]; then
        cat >&2 <<'MSG'
Error: SLURM_ACCOUNT is not set, and this workflow will not submit without it.

Every job would otherwise be charged to your default slurm association, which is
typically your personal account rather than a lab account.

List the accounts you belong to:
    sacctmgr -nP show assoc user=$USER format=Account

Then set it once, for every run directory you clone:
    echo 'SLURM_ACCOUNT=your_account' >> ~/.env

Or for a single run:
    export SLURM_ACCOUNT=your_account

cron does not read your shell profile; ~/.env is read by the launcher itself, so
it works on the cron path too.
MSG
        exit 1
    fi

    # --default-resources on the command line REPLACES the profile's whole
    # default-resources block rather than merging into it, so the other three
    # defaults have to be repeated here or they silently revert to snakemake's
    # built-ins (no partition, dynamic mem_mb, no runtime).
    SLURM_ACCOUNT_ARGS=(--default-resources
        "slurm_account=$SLURM_ACCOUNT"
        "slurm_partition=standard"
        "mem_mb=8000"
        "runtime=60")
}
