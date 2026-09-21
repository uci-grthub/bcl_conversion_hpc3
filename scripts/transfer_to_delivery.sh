#!/bin/bash
# Transfer a finished conversion run to the delivery host.
#
# The one command in the handoff whose flags fail silently when they are wrong:
# --no-g decides whether Nextcloud can read the delivered files at all, and the
# exclusions decide whether the delivery workflow rebuilds or republishes stale
# empty links. Both failures report success from every rule, so the flag list
# lives here rather than being retyped from docs/handoff.md each time. See that
# file for why each exclusion is load-bearing.
#
# Usage:
#   bash scripts/transfer_to_delivery.sh [--dry-run] [--lan] <destination>
#   bash scripts/transfer_to_delivery.sh --list-excluded <destination>
#
#   <destination>      rsync target for THIS run directory, e.g.
#                      dragen:/staging/runs/xR115/ or /mnt/delivery/xR115/
#   --dry-run          pass -n to rsync; nothing is written
#   --lan              add -W (whole-file). Delta encoding is wasted work on
#                      already-compressed FASTQs. Do not add -z for the same reason.
#   --list-excluded    print what the exclusions actually match, via
#                      `rsync -an --out-format='%n'`, and exit. Use this after any
#                      change to the pattern list rather than assuming it bit.
#
# Run from the conversion host (push) with the run directory as the source.
# Requires the run to have reached handoff/manifest.yaml.

set -euo pipefail

DRY_RUN=false
LAN=false
LIST_EXCLUDED=false
DEST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)       DRY_RUN=true ;;
        --lan)           LAN=true ;;
        --list-excluded) LIST_EXCLUDED=true ;;
        -h|--help)       sed -n '2,26p' "$0"; exit 0 ;;
        -*)              echo "ERROR: unknown option: $1" >&2; exit 1 ;;
        *)               if [[ -n "$DEST" ]]; then
                             echo "ERROR: more than one destination given: $DEST and $1" >&2
                             exit 1
                         fi
                         DEST="$1" ;;
    esac
    shift
done

if [[ -z "$DEST" ]]; then
    echo "ERROR: no destination given." >&2
    echo "Usage: bash scripts/transfer_to_delivery.sh [--dry-run] [--lan] <destination>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# The delivery side consumes handoff/manifest.yaml; without it there is nothing
# to deliver and a transfer only moves a half-built run into place.
if [[ ! -f "handoff/manifest.yaml" ]]; then
    echo "ERROR: handoff/manifest.yaml not found in $ROOT_DIR" >&2
    echo "The conversion run has not finished. Nothing to transfer." >&2
    exit 1
fi

# Bare basename globs on purpose. The link logs live one level down at
# logs/{config_id}/project_link_*.log, and a single '*' does not cross a '/', so
# --exclude 'logs/*link*' matches nothing and lets every one of them through.
# ('logs/**/*link*' does work on rsync 3.2.5, since '**' crosses slashes -- but a
# pattern with no '/' matches the basename at any depth, which needs no such
# reasoning about the rsync version or the directory layout.)
# Verify any change with --list-excluded rather than assuming the pattern bit.
EXCLUDES=(
    --exclude '.snakemake/'
    --exclude '.container/'
    # Built on HPC3, for HPC3. docs/handoff.md assumes no host .pixi/ exists on the
    # conversion side (the workflow runs in the container), but run_hpc3.sh's fallback
    # path creates one. A pixi env embeds its own absolute prefix, so shipping this
    # one gives the delivery host an environment naming a path that does not exist
    # there -- which run_delivery.sh may then accept as already installed instead of
    # building from pixi.lock. 1575 paths and 244 symlinks, none of them data.
    --exclude '.pixi/'
    --exclude 'snakemake_config_delivery.yaml'
    --exclude 'project_link*'
    --exclude 'flexbar_project_link*'
    --exclude 'verify_project_link*'
    --exclude 'nextcloud_scan*'
    --exclude 'rescan_nextcloud*'
    # Leading slash on purpose: it anchors the pattern to the root of the
    # transfer, so this is the run's own Reports/ (the order reports, which the
    # delivery host rebuilds and which must not arrive pre-made and looking up to
    # date). Without it the pattern has no internal '/' and matches the basename
    # at any depth -- which drops every output/{config_id}/Reports/ from
    # bcl-convert, and with them Demultiplex_Stats.csv, leaving the order report
    # with "N/A" in every Paired Reads cell and nothing failing.
    --exclude '/Reports/'
)

if $LIST_EXCLUDED; then
    echo "Paths that WOULD transfer (everything not matched by an exclusion):"
    echo ""
    rsync -an --out-format='%n' "${EXCLUDES[@]}" --no-g -a "$ROOT_DIR/" "$DEST"
    echo ""
    echo "Check that no project_link*, nextcloud_scan*, rescan_nextcloud* or"
    echo "top-level Reports/ path appears above -- and that every"
    echo "output/*/Reports/Demultiplex_Stats.csv DOES."
    exit 0
fi

# -a preserves mtimes; without it everything looks newer than its inputs on
# arrival and the delivery host rebuilds what it should accept.
# --no-g lets the destination assign its own group. Plain -a preserves the
# conversion host's group and SUCCEEDS whenever a same-named group exists there,
# so nothing errors -- but Nextcloud's SMB service account cannot read the files,
# `occ files:scan` fails, and the share link resolves to an empty folder.
OPTS=(-aP --no-g)
$LAN && OPTS+=(-W)
$DRY_RUN && OPTS+=(-n)

echo "Source:      $ROOT_DIR/"
echo "Destination: $DEST"
$DRY_RUN && echo "Mode:        DRY RUN (nothing will be written)"
$LAN     && echo "Mode:        LAN (-W, whole-file)"
echo ""

rsync "${OPTS[@]}" "${EXCLUDES[@]}" "$ROOT_DIR/" "$DEST"

echo ""
if $DRY_RUN; then
    echo "Dry run complete. Re-run without --dry-run to transfer."
else
    echo "Transfer complete. On the delivery host:"
    echo "    bash run_delivery.sh --dry-run"
    echo "    bash run_delivery.sh"
    echo ""
    echo "Afterwards check logs/{config_id}/rescan_nextcloud_*.log:"
    echo "Errors must be 0 and Files non-zero. A group-permission failure is"
    echo "silent from the workflow's side."
fi
