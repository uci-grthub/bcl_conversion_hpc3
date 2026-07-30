# SOP: Run the BCL Conversion Snakemake Workflow (HPC3)

Supports **MiSeq i100** and **NovaSeqX** — the platform is auto-detected from the metadata
workbook. `pixi run` auto-loads `.env` and provisions the Python/CLI environment, so
day-to-day commands take no extra flags. bcl-convert itself runs inside a Singularity
container via `run_hpc3.sh` (slurm executor, `profiles/hpc3`) — there is no DRAGEN
instrument involved on HPC3.

## Quickstart (a normal run)

```bash
# 1. Clone into a run-named directory and enter it
cd /path/to/your/runs          # e.g. /dfs9/ucightf-lab/$USER/runs
git clone https://github.com/uci-grthub/bcl_conversion_hpc3 {RUN_NAME}
cd {RUN_NAME}

# 2. Set up the run: creates snakemake_config_project.yaml and prefills
#    metadata / library_name / data_dir from the newest run in the HPC3 staging dir
pixi run init                 # or: pixi run init --staging-dir /dfs3b/ucightf_lab/NSRaw

# 3. Drop the metadata .xlsx into metadata/ (if not already there), then confirm
#    the prefilled config
$EDITOR snakemake_config_project.yaml         # confirm data_dir, library_name, metadata

# 4. Validate metadata + preview the plan (no processing happens)
pixi run validate
bash run_hpc3.sh --dryrun

# 5. Run the full workflow (singularity + slurm via profiles/hpc3)
bash run_hpc3.sh
```

That's the whole loop. `enable_nextcloud`/`send_emails` are **off by default** on HPC3
(`snakemake_config.yaml`), so no `.env` is required unless a project explicitly turns
Nextcloud sharing or email alerts back on.

Two things the workflow now decides on its own, with no operator action:

- **Index collisions.** If a sample's index is a prefix of a longer index on the same lane
  (`GTAGAG` vs `GTAGAGGA`), bcl-convert would abort the lane. That project is dropped from
  the sample sheet and recovered afterwards from Undetermined reads with `fqtk`. Watch for
  `Index collision on lane{N}: ...` in the output; nothing to change in the workbook.
- **Blank `Masking`.** A populated Summary row with an empty `Masking` cell stops the run
  before any conversion. Fix the workbook (see Troubleshooting).

### Prerequisites

First time on HPC3, verify access before anything else — a missing group looks like
"No such file or directory" on a path that plainly exists:

```bash
id | grep -o 'ucightf[a-z_]*'                          # need ucightf AND ucightf_lab_share
sacctmgr -nP show assoc user=$USER format=Account      # need a slurm account
ls /dfs9/ucightf-lab/containers/bcl_convert.sif        # need the container
```

- **Group `ucightf`** — `/dfs9/ucightf-lab` (container, lab scratch) is `drwxrws---`.
- **Group `ucightf_lab_share`** — `/dfs3b/ucightf_lab/NSRaw` (BCL staging) likewise.
- **A slurm account.** The profile pins `sbsandme_lab`; if that is not yours,
  `export SLURM_ACCOUNT=<your_account>` and `run_hpc3.sh` uses it instead.
- Run has finished copying (a `CopyComplete.txt` exists in the run directory under
  `/dfs3b/ucightf_lab/NSRaw/...`).
- A SampleSheet `.xlsx` from the lab, placed in `metadata/`.
- **pixi** installed once: `curl -fsSL https://pixi.sh/install.sh | bash`, then
  `pixi install` to build the environment from `pixi.lock`.
- **Singularity** available via `module load singularity` (already wired into the rules
  that need it).
- **The bcl-convert container.** Not installed by pixi, not in the repo. Lives at
  `/dfs9/ucightf-lab/containers/bcl_convert.sif`, readable by group `ucightf`, and is
  hardcoded as `CONTAINER_SIF` near the top of the `Snakefile`. Nothing to configure.
  See [README.md](README.md#container-image) for how the image is built.

---

## Reference

### Credentials (`.env`) — optional on HPC3

Only needed if a project sets `enable_nextcloud: true` or `send_emails: true` in
`snakemake_config_project.yaml` (both default `false`). If enabled, the workflow needs:

| Variable | What it is |
| --- | --- |
| `NEXTCLOUD_URL` | Nextcloud instance, e.g. `https://precision.biochem.uci.edu` |
| `NEXTCLOUD_USER` | Nextcloud account owning the share directory |
| `NEXTCLOUD_PASSWORD` | **App password** for that account (not the login password) |
| `GMAIL_APP_PASSWORD` | App password for the `email_sender` account |

Credentials live in **`~/.env`** — written once, reused by every run directory you
clone, and outside every repo so they cannot be committed by accident:

```bash
cp .env.example ~/.env && chmod 600 ~/.env
$EDITOR ~/.env
```

`pixi run` sources it automatically (`scripts/load_dotenv.sh`), then layers a
run-local `./.env` on top if one exists — use that only when a single run needs
different credentials than your usual ones. Generate a Nextcloud app password under
**Settings > Personal > Security > Devices & sessions > Create new app password**.

Verify access before relying on it:

```bash
pixi run python scripts/test_nextcloud_token.py
```

### Configuration files

- `snakemake_config_project.yaml` — per-run overrides (gitignored). `pixi run init`
  prefills `library_name`, `metadata`, `data_dir`. Set `email_sender` /
  `email_recipient` / `email_cc` only if enabling email (base config ships these blank
  so a run never emails the previous operator), plus optional `external_drive_path`,
  `scratch_dir`, `tiles`, `flexbar_bin`.
- `snakemake_config.yaml` — base defaults, layered under the project file. Rarely edited;
  `send_emails: false` / `enable_nextcloud: false` live here.
- `profiles/hpc3/config.yaml` — the HPC3 executor profile: slurm executor, Singularity
  enabled, `standard` partition, account `sbsandme_lab` (override with `$SLURM_ACCOUNT`),
  `cores: 32` (must stay >= the largest rule `threads:`), up to 32 concurrent jobs,
  `keep-going`, `latency-wait: 120` (dfs9 is slow to expose outputs), `rerun-triggers: mtime`
  (an unrelated Snakefile edit won't re-run bcl-convert), and 8000 MB / 60 min defaults.
  Used automatically by `run_hpc3.sh`. Heavy rules override these in the `Snakefile`:
  `bcl_convert`/`bcl_convert_rc` 24 threads / 48 GB, `flexbar_per_config` 32 / 64 GB / 480 min,
  `fqtk_per_config` 8 / 16 GB / 480 min.
- `profiles/default/config.yaml` — non-HPC3 resource-limit profile (kept for parity with
  upstream / single-host use); not used by `run_hpc3.sh`, which passes
  `--workflow-profile none` so this profile cannot silently override the hpc3 one.

### Metadata format (auto-detected)

- **NovaSeqX** (has a `Summary` sheet):
  - Summary sheet (header row 3): `Lane`, `Gr` (Group), `Project Name`, `Masking`, `Fastq Link`
  - Per-project sheets: `Lane`, `Group`, `Sample Name`, `i7 Barcode Sequence`, `i5 Barcode Sequence`
  - Masking strings must match the run cycle structure in `RunInfo.xml`.
  - Every populated Summary row **must** carry a `Masking` value — a blank one is a fatal error.
- **MiSeq i100** (has a `Barcode Entries` sheet, no `Summary` sheet):
  - Per-sample barcodes; Order IDs inferred from the `Lab ID` column; all samples in `lane1`.

### Post-hoc demultiplexing (fqtk)

Runs automatically for a lane when `metadata/fqtk_barcodes_lane{N}.tsv` exists — written by
sample-sheet generation for projects named `*fqtk*` and for projects routed there by an index
prefix collision. Those samples are demultiplexed from the lane's Undetermined I1 reads after
conversion, then staged into the project directory under normal names; their read counts come
from `output/lane{N}/fqtk/demux-metrics.txt` instead of `Demultiplex_Stats.csv`.

Nothing to run by hand. To inspect one lane:

```bash
bash run_hpc3.sh results/lane2/fqtk_lane2.done
cat logs/lane2/fqtk_lane2.log                        # resolved barcodes + thresholds
cat metadata/fqtk_barcodes_lane2_resolved.tsv        # full-length barcodes and decoys
```

Details in [README.md](README.md#fqtk-post-hoc-demultiplexing).

### Run specific stages

Configs are per lane (`lane1`…`lane8`; MiSeq uses only `lane1`). Pass a target through
`run_hpc3.sh` (or `pixi run snakemake --profile profiles/hpc3` directly):

```bash
bash run_hpc3.sh output/lane1                                       # BCL conversion, one lane
pixi run snakemake --profile profiles/hpc3 --cores 4 results/fastp_lane1.done
pixi run snakemake --profile profiles/hpc3 --cores 1 Reports/order_0626I-08/index.html
pixi run snakemake --profile profiles/hpc3 --cores 1 results/{RUN}-count.csv
pixi run snakemake --profile profiles/hpc3 -R compile_read_counts   # force a rule to re-run
```

### Validate outputs

- `output/lane{N}/` — project FASTQ files
- `output/lane{N}/fqtk/` — post-hoc demux output + `demux-metrics.txt` (routed lanes only)
- `results/fastp/` — JSON stats; `results/fastp_plots/` — PNG plots
- `Reports/` — order/project HTML reports, md5sums, PDFs (if enabled)
- `results/{RUN}-count.csv` — read counts

### Automated launch (cron)

`monitor_and_run_snakemake.sh` waits for `CopyComplete.txt` in `data_dir` and launches
`run_hpc3.sh` in a tmux session named after the library. See `CRON_INSTRUCTIONS.txt`.

### Dependency graphs

```bash
pixi run rulegraph            # rulegraph.png
pixi run dag                  # dag.pdf
```

### Troubleshooting quick checks

- Missing lanes: confirm `data_dir` and detected lanes in the dry run.
- BCL conversion failures: check the Singularity module/image, and slurm job logs.
- `bcl_convert.sif: No such file or directory` — you are almost certainly not in group
  `ucightf` (`id | grep ucightf`); the image is there, the directory is just unreadable
  to you. Ask RCIC or the PI to add you.
- `sbatch: error: Invalid account` — `export SLURM_ACCOUNT=$(sacctmgr -nP show assoc
  user=$USER format=Account | head -1)` and rerun.
- Container cannot see your files (`No such file or directory` on a path that exists) —
  your working directory or `data_dir` is on a filesystem outside `SINGULARITY_BINDS`
  (`/dfs3b,/dfs9` in the `Snakefile`). Add it there, or work under one of those.
- Empty reports: verify metadata sheet names and headers.
- md5 mismatch: regenerate the specific project report outputs.
- `Missing Masking value in Summary tab for: lane N group G` — fill that cell in the workbook.
  Bypass only when the blank is intentional: `ALLOW_MISSING_MASKING=1 bash run_hpc3.sh`.
- `UNRESOLVABLE i7 prefix collision` from the barcode validator — mixed index lengths that no
  `BarcodeMismatchesIndex` value can separate. Pad/replace the short index in the workbook, or
  let the fqtk routing handle it (it normally does, before bcl-convert sees the sheet).
- Job OOM-killed / hit the time limit — compare `benchmarks/{rule}_{config_id}.bench` and raise
  that rule's `resources:` block in the `Snakefile`; the profile default is 8000 MB / 60 min.
- Only one job running at a time — confirm `run_hpc3.sh` was used (it passes
  `--workflow-profile none`); a bare `snakemake` picks up `profiles/default` and serializes.
