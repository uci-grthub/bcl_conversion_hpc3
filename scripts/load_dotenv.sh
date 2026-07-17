#!/bin/bash
# Sourced by pixi as an activation script (see [activation] in pixi.toml).
# Loads the required secrets so every `pixi run ...` has them — no manual
# `set -a; source .env; set +a`, and normally no per-run .env at all.
#
# Search order (later wins), all optional:
#   1. ../.env  — shared per-platform secrets (NovaSeqX/.env, MiSeqi100/.env).
#                 This is the normal source; a fresh clone needs no local .env.
#   2. ./.env   — per-run override, for an operator using their own credentials.
#
# Runs at the pixi manifest root (the run directory). Both files are optional on
# HPC3: enable_nextcloud/send_emails default to false, so a fresh clone needs no
# .env at all unless a project turns those on.
set -a
[ -f ../.env ] && . ../.env
[ -f ./.env ]  && . ./.env
set +a

# Re-pin the workflow profile regardless of anything a sourced .env set. A
# shared ../.env may export SNAKEMAKE_PROFILE pointing at a personal global
# profile; the repo's profiles/hpc3 (slurm executor + Singularity) is the one
# that must win for every operator on this cluster.
export SNAKEMAKE_PROFILE="profiles/hpc3"
