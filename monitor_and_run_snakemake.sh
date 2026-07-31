#!/bin/bash
# Script to monitor a directory for CopyComplete.txt and trigger Snakemake
# Reads the directory path from snakemake_config_project.yaml (key: data_dir)

set -e

cd "$(realpath "$(dirname "$0")")"

# Config is read with sed, not `python3 -c "import yaml"`. cron runs with a
# minimal PATH, and the workflow no longer needs a host python at all — the
# container supplies one — so a host yaml module here would be the last thing
# keeping a host environment mandatory.
# shellcheck source=scripts/read_config_key.sh
. scripts/read_config_key.sh

MONITOR_DIR="$(read_config_key data_dir || true)"

if [ -z "$MONITOR_DIR" ]; then
  echo "data_dir not set in snakemake_config_project.yaml. Exiting."
  exit 1
fi

TARGET_FILE="$MONITOR_DIR/CopyComplete.txt"

if [ -f "$TARGET_FILE" ]; then
  echo "Found $TARGET_FILE. Triggering Snakemake in tmux session."
  LIBRARY="$(read_config_key library_name || echo snakemake)"
  # Check if tmux session already exists
  if tmux has-session -t "$LIBRARY" 2>/dev/null; then
    echo "tmux session $LIBRARY already exists. Not starting a new one."
  else
    # run_hpc3_container.sh sources .env itself and pins --profile profiles/hpc3,
    # so no env sourcing or profile flag is needed here. It leaves an
    # interactive shell behind afterwards so the operator can inspect the run.
    tmux new-session -d -c "$(pwd)" -s "$LIBRARY" "bash run_hpc3_container.sh; exec bash"
    if [ $? -ne 0 ]; then
      echo "Failed to start tmux session $LIBRARY."
    else
      echo "Started tmux session $LIBRARY."
    fi
  fi
else
  echo "$TARGET_FILE not found. No action taken."
fi