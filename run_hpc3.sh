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

# Per-user: /tmp is node-local and shared, so a fixed name is owned by whoever
# ran first and everyone else gets permission-denied writes inside it.
mkdir -p "/tmp/bcl-convert-logs-$(id -un)"

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

# Per-operator slurm account, from $SLURM_ACCOUNT (usually ~/.env). Hard error
# when unset; see scripts/require_slurm_account.sh for why it is not a profile
# default and why unset cannot mean "let slurm decide".
# shellcheck source=scripts/require_slurm_account.sh
source "$(cd "$(dirname "$0")" && pwd)/scripts/require_slurm_account.sh"
require_slurm_account
SNAKEMAKE_ARGS+=("${SLURM_ACCOUNT_ARGS[@]}")

if [[ "$DRY_RUN" -eq 1 ]]; then
    SNAKEMAKE_ARGS+=(--dry-run)
fi
SNAKEMAKE_ARGS+=("${PASSTHROUGH_ARGS[@]}")

"${SNAKEMAKE_ARGS[@]}"
