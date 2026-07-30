#!/bin/bash
# Sourced by pixi as an activation script (see [activation] in pixi.toml).
# Loads the required secrets so every `pixi run ...` has them — no manual
# `set -a; source .env; set +a`.
#
# Search order (later wins), all optional:
#   1. ~/.env   — your personal credentials, written once and picked up by every
#                 run directory you clone. This is the normal source; it lives
#                 outside every repo, so it can never be committed by accident.
#   2. ./.env   — per-run override, for a run needing different credentials than
#                 your usual ones.
#
# Runs at the pixi manifest root (the run directory). Both files are optional on
# HPC3: enable_nextcloud/send_emails default to false, so a fresh clone needs no
# .env at all unless a project turns those on. See .env.example for the keys.
set -a
# shellcheck source=/dev/null  # both files are optional and created by the operator
[ -f "$HOME/.env" ] && . "$HOME/.env"
# shellcheck source=/dev/null
[ -f ./.env ]       && . ./.env
set +a

# Re-pin the workflow profile regardless of anything a sourced .env set. A
# personal ~/.env may export SNAKEMAKE_PROFILE pointing at a global profile;
# the repo's profiles/hpc3 (slurm executor + Singularity) is the one that must
# win for every operator on this cluster.
export SNAKEMAKE_PROFILE="profiles/hpc3"
