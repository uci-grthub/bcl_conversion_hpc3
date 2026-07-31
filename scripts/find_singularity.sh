#!/usr/bin/env bash
# Resolve an absolute path to a singularity/apptainer binary, without Lmod.
#
# `module load singularity` defines a shell *function*, which is useless to
# everything that is not an interactive bash on a login node: the container
# launcher, the generated compute-node python shim, and (historically) the
# Snakefile's `run:` blocks all need a real path. This is the single
# implementation of that lookup; sourcing it and calling `find_singularity` is
# the only supported way to get one.
#
# Usage:
#   source scripts/find_singularity.sh
#   SINGULARITY="$(find_singularity)" || exit 1

find_singularity() {
    local exe

    # Already on PATH (module loaded, or a site where it just is).
    for exe in singularity apptainer; do
        if command -v "$exe" >/dev/null 2>&1; then
            command -v "$exe"
            return 0
        fi
    done

    # HPC3 installs under /opt/apps/singularity/<version>/bin. Sort with -V,
    # not plain sort: lexicographically "3.9.4" beats "3.11.3", which would
    # silently pick an older singularity than the one available.
    local newest
    newest="$(ls -d /opt/apps/singularity/*/bin/singularity 2>/dev/null | sort -V | tail -n 1)"
    if [[ -n "$newest" && -x "$newest" ]]; then
        printf '%s\n' "$newest"
        return 0
    fi

    echo "Error: no singularity/apptainer on PATH and nothing under" \
         "/opt/apps/singularity/*/bin/singularity." >&2
    echo "Run \`module load singularity\` first, or install apptainer." >&2
    return 1
}
