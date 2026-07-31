#!/usr/bin/env bash
# The bind list shared by the container launcher and the compute-node shim.
#
# Both ends must use exactly the same set: the driver submits from inside the
# container, and every job it spawns re-enters the same image. A bind present in
# one and missing in the other produces failures that only show up on the
# compute node, minutes after submission.
#
# Usage:
#   source scripts/container_binds.sh
#   container_binds            # prints one --bind argument per line
#   container_binds_flat       # prints them space-joined, for embedding in a shim

# Data. /dfs3b holds the BCL run directories, /dfs9 the lab share and the run
# working directories. A clone on another filesystem (/pub/$USER, say) must add
# it here or the container cannot see its own inputs and outputs.
CONTAINER_DATA_BINDS=(
    /dfs3b
    /dfs9
)

# SLURM client. The image ships no slurm packages: the host's binaries and
# libraries are bound in, so the container tracks HPC3's slurm version through
# upgrades automatically instead of drifting out of lockstep with slurmctld.
#
#   /usr/lib64/slurm        libslurmfull.so plus the auth/hash plugins
#   /usr/lib64/libmunge.so.2  dlopened by auth_munge.so, and NOT under
#                             /usr/lib64/slurm -- verified with
#                             `ldd /usr/lib64/slurm/auth_munge.so`
#   /var/run/munge          the munge socket the auth plugin talks to
#   /etc/slurm              slurm.conf and friends
# This is the full set the snakemake slurm executor plugin shells out to, taken
# from the plugin source rather than guessed -- sacctmgr in particular is called
# during submission to resolve the account, and its absence fails every job with
# a bare "[Errno 2] No such file or directory: 'sacctmgr'".
CONTAINER_SLURM_BINDS=(
    /usr/bin/sbatch
    /usr/bin/srun
    /usr/bin/squeue
    /usr/bin/scancel
    /usr/bin/sacct
    /usr/bin/sacctmgr
    /usr/bin/scontrol
    /usr/bin/sinfo
    /usr/bin/sstat
    /usr/bin/sattach
    /usr/lib64/slurm
    /usr/lib64/libmunge.so.2
    /etc/slurm
    /var/run/munge
)

# bcl-convert writes to /var/log/bcl-convert and aborts if that path is
# read-only. --writable-tmpfs alone is not enough: the overlay is small and the
# logs are not, so point it at real disk.
CONTAINER_LOG_BIND="/tmp/bcl-convert-logs:/var/log/bcl-convert"

# Paths the site already binds by default. HPC3's singularity.conf lists /dfs3b,
# /dfs9 and /data/homezvol*, so naming them again is harmless but makes
# singularity print
#     WARNING: While bind mounting '/dfs9:/dfs9': destination is already in the
#     mount point list
# on every invocation -- including once per spawned job, in every slurm log.
# They stay in the lists above so the launcher still works at a site that does
# not pre-bind them; they are just filtered out when the local config covers them.
_container_default_binds() {
    local exe="${1:-}" conf
    [[ -n "$exe" ]] || return 0
    conf="$(dirname "$(dirname "$exe")")/etc/singularity/singularity.conf"
    [[ -r "$conf" ]] || return 0
    sed -n 's/^[[:space:]]*bind path[[:space:]]*=[[:space:]]*\([^[:space:],#]*\).*/\1/p' "$conf"
}

_container_is_covered() {
    local p="$1" d
    shift
    for d in "$@"; do
        [[ "$p" == "$d" || "$p" == "$d"/* ]] && return 0
    done
    return 1
}

# Usage: container_binds [/abs/path/to/singularity]
# The argument is optional; without it nothing is filtered.
container_binds() {
    local defaults=()
    mapfile -t defaults < <(_container_default_binds "${1:-}")

    # Single-node launchers (run_local*.sh) set CONTAINER_SKIP_SLURM_BINDS: the
    # driver never submits, so a host slurm client is dead weight at best. At
    # worst the host has a partial install -- an /etc/slurm and a libmunge left
    # behind with no sbatch -- which the [[ -e ]] test below happily binds in.
    local bind_list=("${CONTAINER_DATA_BINDS[@]}")
    if [[ -z "${CONTAINER_SKIP_SLURM_BINDS:-}" ]]; then
        bind_list+=("${CONTAINER_SLURM_BINDS[@]}")
    fi

    local p
    for p in "${bind_list[@]}"; do
        # Skip anything absent rather than failing the whole run: a site without
        # /dfs3b, or a slurm build that puts sinfo elsewhere, should still work.
        [[ -e "$p" ]] || continue
        _container_is_covered "$p" "${defaults[@]}" && continue
        printf -- '--bind %s\n' "$p"
    done

    # Always emitted: it remaps a path rather than exposing one, so a default
    # bind of /tmp does not make it redundant.
    printf -- '--bind %s\n' "$CONTAINER_LOG_BIND"

    # rescan_nextcloud ssh's to the Nextcloud host.
    if [[ -d "$HOME/.ssh" ]] && ! _container_is_covered "$HOME/.ssh" "${defaults[@]}"; then
        printf -- '--bind %s\n' "$HOME/.ssh"
    fi

    # A checkout outside everything above (a git worktree in /pub, for instance)
    # still has to be visible.
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if ! _container_is_covered "$here" "${CONTAINER_DATA_BINDS[@]}" "${defaults[@]}"; then
        printf -- '--bind %s\n' "$here"
    fi

    # Escape hatch for anything site-specific: extra filesystems, or an
    # /etc/passwd carrying a user the image lacks. Space-separated bind specs,
    # passed through verbatim.
    #   export CONTAINER_EXTRA_BINDS="/pub/$USER /scratch:/scratch"
    local extra
    for extra in ${CONTAINER_EXTRA_BINDS:-}; do
        printf -- '--bind %s\n' "$extra"
    done
}

container_binds_flat() {
    container_binds "${1:-}" | tr '\n' ' '
}
