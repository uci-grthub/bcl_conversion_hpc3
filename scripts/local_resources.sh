#!/usr/bin/env bash
# Host sizing for the single-node path, shared by run_local.sh and
# run_local_container.sh so the two can never drift.
#
# On hpc3 every rule gets its own allocation, so its `resources:` are a request
# and SLURM finds a node that fits. On one machine they are a budget: Snakemake
# schedules against whatever `--cores` / `--resources mem_mb` the driver was
# given, and a rule asking for more memory than the global limit is a hard DAG
# error, not a queue wait:
#     Job needs mem_mb=64000 which exceeds the available mem_mb=32000
# So measure the host, then clamp the rules that overshoot it.
#
# Usage:
#   source scripts/local_resources.sh
#   local_resources                      # sets the three variables below
#   snakemake --cores "$LOCAL_CORES" --resources "mem_mb=$LOCAL_MEM_MB" \
#             "${LOCAL_SET_RESOURCES[@]}"
#
# Overrides, for a shared machine or a deliberately small test run:
#   BCL_LOCAL_CORES, BCL_LOCAL_MEM_MB

# The declared `mem_mb` of every rule that asks for more than the 8000 default.
# Keep in sync with the Snakefile; a rule missing here is simply never clamped,
# which shows up as the DAG error quoted above rather than as silent corruption.
LOCAL_RULE_MEM_MB=(
    flexbar_per_config:64000
    flexbar_pair_r2:32000
    bcl_convert:48000
    bcl_convert_rc:48000
    fqtk_per_config:16000
)

# The largest `threads:` in the Snakefile (flexbar_per_config, flexbar_pair_r2).
LOCAL_MAX_RULE_THREADS=32

# fastp_sample's mem_mb is a callable, get_fastp_mem_mb (src/workflow_defs.smk),
# so the table above cannot clamp it: the value is only known at DAG time, once
# per sample. It returns max(8000, input_size/2 + 4000), and its own comment
# says why -- "HPC3-specific: scale fastp memory by input FASTQ size ... HPC3
# jobs request mem dynamically". That is a request-sizing device for a scheduler
# picking a node, not a measured requirement; fastp streams its input.
#
# On one machine it does no good and two kinds of harm: a FASTQ over twice the
# budget fails the whole DAG outright, and a merely large one reserves most of
# the budget for a single sample, serializing all 179 of them. So pin it to the
# heuristic's own floor (or the whole budget, if the budget is somehow smaller).
LOCAL_FASTP_MEM_MB=8000

local_resources() {
    # nproc honours cgroup and affinity limits, so it stays correct inside a
    # container or under `taskset` -- unlike /proc/cpuinfo.
    LOCAL_CORES="${BCL_LOCAL_CORES:-$(nproc)}"

    if [[ -z "${BCL_LOCAL_MEM_MB:-}" ]]; then
        if [[ ! -r /proc/meminfo ]]; then
            echo "Error: cannot read /proc/meminfo to size this host." >&2
            echo "Set BCL_LOCAL_MEM_MB=<megabytes> explicitly." >&2
            return 1
        fi
        # 90% of physical RAM. The 10% is not padding for its own sake: rules
        # declare only what Snakemake accounts for, while bcl-convert's own
        # buffers, the page cache for a multi-TB BCL tree, and the driver
        # process itself all live outside that accounting.
        LOCAL_MEM_MB="$(awk '/^MemTotal:/ {print int($2 / 1024 * 0.9)}' /proc/meminfo)"
    else
        LOCAL_MEM_MB="$BCL_LOCAL_MEM_MB"
    fi

    if [[ ! "$LOCAL_CORES" =~ ^[0-9]+$ ]] || (( LOCAL_CORES < 1 )); then
        echo "Error: bad core count '$LOCAL_CORES' (set BCL_LOCAL_CORES)." >&2
        return 1
    fi
    if [[ ! "$LOCAL_MEM_MB" =~ ^[0-9]+$ ]] || (( LOCAL_MEM_MB < 1000 )); then
        echo "Error: bad memory budget '$LOCAL_MEM_MB' MB (set BCL_LOCAL_MEM_MB)." >&2
        return 1
    fi

    LOCAL_SET_RESOURCES=()
    local spec rule want clamped=()
    for spec in "${LOCAL_RULE_MEM_MB[@]}"; do
        rule="${spec%%:*}"
        want="${spec##*:}"
        if (( want > LOCAL_MEM_MB )); then
            LOCAL_SET_RESOURCES+=(--set-resources "${rule}:mem_mb=${LOCAL_MEM_MB}")
            clamped+=("$spec")
        fi
    done

    # Replace the dynamic fastp heuristic with a flat value. Unconditional, so
    # it is not reported as a clamp below -- see LOCAL_FASTP_MEM_MB above for
    # why this is a fix rather than a downgrade.
    local fastp_mem="$LOCAL_FASTP_MEM_MB"
    (( fastp_mem > LOCAL_MEM_MB )) && fastp_mem="$LOCAL_MEM_MB"
    LOCAL_SET_RESOURCES+=(--set-resources "fastp_sample:mem_mb=${fastp_mem}")

    echo "Single-node budget: ${LOCAL_CORES} cores, ${LOCAL_MEM_MB} MB." >&2
    if (( ${#clamped[@]} > 0 )); then
        # Worth saying out loud: a clamped bcl_convert or flexbar still runs,
        # but it is now running in less memory than the rule was written for.
        echo "  Clamped to fit (declared mem_mb exceeds the budget):" >&2
        for spec in "${clamped[@]}"; do
            echo "    ${spec%%:*} (${spec##*:} MB)" >&2
        done
    fi
    if (( LOCAL_CORES < LOCAL_MAX_RULE_THREADS )); then
        # Not an error: Snakemake silently downscales any `threads:` above
        # --cores. Silently is the problem -- say it once so a slow flexbar is
        # not a mystery later.
        echo "  Note: rules declaring up to ${LOCAL_MAX_RULE_THREADS} threads" \
             "(flexbar) will run at ${LOCAL_CORES}." >&2
    fi
}
