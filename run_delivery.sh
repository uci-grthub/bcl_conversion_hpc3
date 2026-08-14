#!/usr/bin/env bash
set -euo pipefail

# Delivery half of the pipeline: Nextcloud share links, order reports, emails.
# Run this on the dragen server, in a run directory rsynced from HPC3.
#
#   bash run_delivery.sh                  # links + reports + emails
#   bash run_delivery.sh --dry-run
#   bash run_delivery.sh links_only       # share links and verification only
#   bash run_delivery.sh reports_only     # links + HTML/PDF/md5, no email
#   bash run_delivery.sh --skip-verify    # skip the pre-flight rsync check
#
# The conversion half runs on HPC3 (`bash run_hpc3_container.sh`) and ends by
# writing handoff/manifest.yaml. See docs/handoff.md.

here="$(cd "$(dirname "$0")" && pwd)"

# Re-exec inside the pixi env if not already there, for the same reason as
# run_hpc3.sh: a stray conda env earlier on PATH shadows pixi's snakemake.
#
# pixi is resolved to an absolute path rather than invoked by bare name: its
# installer only puts ~/.pixi/bin on PATH via a shell rc, so `ssh host
# 'bash run_delivery.sh'`, cron and batch jobs all get command-not-found from an
# installed pixi. That first `pixi run` also builds the environment from
# pixi.lock if the run directory has no .pixi yet, which is the normal state for
# a run rsynced from HPC3 (the conversion side runs in the container and never
# builds a host env).
if [[ -z "${PIXI_ENVIRONMENT_NAME:-}" ]]; then
    # shellcheck source=scripts/find_pixi.sh
    source "$here/scripts/find_pixi.sh"
    PIXI="$(find_pixi)" || exit 1
    exec "$PIXI" run --manifest-path "$here/pixi.toml" bash "$0" "$@"
fi

SKIP_VERIFY=0
VERIFY_ARGS=()
PASSTHROUGH_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --skip-verify)
            SKIP_VERIFY=1
            ;;
        --verify-md5)
            VERIFY_ARGS+=(--md5)
            ;;
        *)
            PASSTHROUGH_ARGS+=("$arg")
            ;;
    esac
done

if [[ ! -d handoff/projects ]]; then
    echo "Error: no handoff/projects/ in $(pwd)." >&2
    echo "Run the conversion workflow on HPC3 and rsync the run directory here first." >&2
    exit 1
fi

# The delivery config is per run directory and untracked, so a freshly rsynced run
# arrives without one. Create it from the tracked template and stop: this workflow
# publishes data and mails customers, so the first run in a directory should not
# proceed on defaults nobody looked at.
if [[ ! -f snakemake_config_delivery.yaml ]]; then
    cp "$here/snakemake_config_delivery.yaml.example" snakemake_config_delivery.yaml
    echo "Created snakemake_config_delivery.yaml from the template."
    echo "Review it -- in particular send_emails and email_recipient -- then re-run:"
    echo "    \$EDITOR snakemake_config_delivery.yaml"
    echo "    bash run_delivery.sh $*"
    exit 1
fi

# Report every gap in the transfer at once. Snakemake would also catch a missing
# file, but one at a time, after the DAG is built and possibly after some shares
# have already been published.
if [[ "$SKIP_VERIFY" -eq 0 ]]; then
    python3 "$here/scripts/verify_handoff.py" "${VERIFY_ARGS[@]}"
fi

# --profile is passed explicitly because the pixi activation script exports
# SNAKEMAKE_PROFILE=profiles/hpc3 for the conversion workflow; delivery runs
# locally on the dragen server, not through slurm.
# --workflow-profile none keeps snakemake from also auto-merging profiles/default
# on top of the explicit --profile.
exec snakemake \
    -s "$here/Snakefile.delivery" \
    --profile profiles/default \
    --workflow-profile none \
    "${PASSTHROUGH_ARGS[@]}"
