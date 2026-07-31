# SOP: Run the BCL Conversion Snakemake Workflow (HPC3)

Supports **MiSeq i100** and **NovaSeqX** — the platform is auto-detected from the metadata
workbook. The whole workflow runs inside a Singularity container — every tool and the
Snakemake driver itself — launched by `run_hpc3_container.sh` (slurm executor,
`profiles/hpc3`). There is no DRAGEN instrument involved on HPC3.

`pixi run` is the host fallback path, used below for the setup steps that happen before
a run starts; it auto-loads `.env` and provisions the Python/CLI environment. If you
have no pixi env, `bash run_hpc3_container.sh` still works on its own — `module load
singularity` is the only host requirement.

**This SOP is the HPC3 procedure.** To run the same workflow on one machine with no
scheduler, substitute `run_local_container.sh` for `run_hpc3_container.sh` throughout and
skip everything about slurm accounts; see
[README.md](README.md#single-node--no-slurm-execution) for how it sizes itself to the host.

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
module load singularity
pixi run validate
bash run_hpc3_container.sh --dryrun

# 5. Run the full workflow (singularity + slurm via profiles/hpc3)
bash run_hpc3_container.sh
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
ls /dfs9/ucightf-lab/kstachel/containers/bcl_convert_docker_v2.sif        # need the container
```

- **Group `ucightf`** — `/dfs9/ucightf-lab` (container, lab scratch) is `drwxrws---`.
- **Group `ucightf_lab_share`** — `/dfs3b/ucightf_lab/NSRaw` (BCL staging) likewise.
- **A slurm account.** The profile pins `sbsandme_lab`; if that is not yours,
  `export SLURM_ACCOUNT=<your_account>` and `run_hpc3_container.sh` uses it instead.
- Run has finished copying (a `CopyComplete.txt` exists in the run directory under
  `/dfs3b/ucightf_lab/NSRaw/...`).
- A SampleSheet `.xlsx` from the lab, placed in `metadata/`.
- **Singularity** available via `module load singularity`. The only host requirement
  for a run.
- **The container.** Not in the repo. Lives at
  `/dfs9/ucightf-lab/kstachel/containers/bcl_convert_docker_v2.sif`, readable by group
  `ucightf`, named by `container_sif` in `snakemake_config.yaml`. Nothing to configure.
  It holds every tool *and* the Snakemake driver.
- **pixi**, only for the host fallback path and the setup tasks: `curl -fsSL
  https://pixi.sh/install.sh | bash`, then `pixi install`.
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
- `profiles/hpc3/config.yaml` — the HPC3 executor profile: slurm executor,
  `standard` partition, account `sbsandme_lab` (override with `$SLURM_ACCOUNT`),
  `cores: 32` (must stay >= the largest rule `threads:`), up to 32 concurrent jobs,
  `keep-going`, `latency-wait: 120` (dfs9 is slow to expose outputs), `rerun-triggers: mtime`
  (an unrelated Snakefile edit won't re-run bcl-convert), and 8000 MB / 60 min defaults.
  Used automatically by `run_hpc3_container.sh`. Heavy rules override these in the `Snakefile`:
  `bcl_convert`/`bcl_convert_rc` 24 threads / 48 GB, `flexbar_per_config` 32 / 64 GB / 480 min,
  `fqtk_per_config` 8 / 16 GB / 480 min.
- `profiles/local/config.yaml` — the single-node profile: `executor: local`, so rules run
  as child processes of the driver and nothing is submitted. Used by `run_local_container.sh`
  and `run_local.sh`, which size `cores`/`mem_mb` to the host rather than hardcoding them.
- `profiles/default/config.yaml` — the legacy DRAGEN-server profile, kept for parity with
  upstream. Not used by any launcher here; every launcher passes `--workflow-profile none`
  so it cannot silently override the profile that was asked for. For single-host runs use
  `profiles/local` instead — this one has no `executor` and carries DRAGEN-era FPGA
  assumptions.

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
bash run_hpc3_container.sh results/lane2/fqtk_lane2.done
cat logs/lane2/fqtk_lane2.log                        # resolved barcodes + thresholds
cat metadata/fqtk_barcodes_lane2_resolved.tsv        # full-length barcodes and decoys
```

Details in [README.md](README.md#fqtk-post-hoc-demultiplexing).

### Run specific stages

Configs are per lane (`lane1`…`lane8`; MiSeq uses only `lane1`). Pass a target through
`run_hpc3_container.sh`:

```bash
bash run_hpc3_container.sh output/lane1                             # BCL conversion, one lane
bash run_hpc3_container.sh results/fastp_lane1.done
bash run_hpc3_container.sh Reports/order_0626I-08/index.html
bash run_hpc3_container.sh results/{RUN}-count.csv
bash run_hpc3_container.sh -R compile_read_counts                   # force a rule to re-run
```

On the host fallback path, calling `snakemake` directly needs **`--workflow-profile none`**
as well — without it Snakemake merges `profiles/default` over your `--profile` and its
`serial_operation=1` silently serializes the run (see the last troubleshooting entry):

```bash
pixi run snakemake --profile profiles/hpc3 --workflow-profile none --cores 4 results/fastp_lane1.done
```

### Validate outputs

- `output/lane{N}/` — project FASTQ files
- `output/lane{N}/fqtk/` — post-hoc demux output + `demux-metrics.txt` (routed lanes only)
- `results/fastp/` — JSON stats; `results/fastp_plots/` — PNG plots
- `Reports/` — order/project HTML reports, md5sums, PDFs (if enabled)
- `results/{RUN}-count.csv` — read counts

### Automated launch (cron)

`monitor_and_run_snakemake.sh` waits for `CopyComplete.txt` in `data_dir` and launches
`run_hpc3_container.sh` in a tmux session named after the library. It needs no pixi. See `CRON_INSTRUCTIONS.txt`.

### Dependency graphs

```bash
pixi run rulegraph            # rulegraph.png
pixi run dag                  # dag.pdf
```

### Troubleshooting quick checks

- Missing lanes: confirm `data_dir` and detected lanes in the dry run.
- BCL conversion failures: check the Singularity module/image, and slurm job logs.
- `bcl_convert_docker_v2.sif: No such file or directory` — you are almost certainly not in group
  `ucightf` (`id | grep ucightf`); the image is there, the directory is just unreadable
  to you. Ask RCIC or the PI to add you.
- `sbatch: error: Invalid account` — `export SLURM_ACCOUNT=$(sacctmgr -nP show assoc
  user=$USER format=Account | head -1)` and rerun.
- Container cannot see your files (`No such file or directory` on a path that exists) —
  your working directory or `data_dir` is on a filesystem outside the container binds
  (`/dfs3b`, `/dfs9`). Easiest fix is the escape hatch, no file edit needed:
  `export CONTAINER_EXTRA_BINDS="/pub/$USER"`. For a path every operator needs, add it to
  `CONTAINER_DATA_BINDS` in `scripts/container_binds.sh` instead. (The repo checkout itself
  is bound automatically when it falls outside the defaults.)
- Empty reports: verify metadata sheet names and headers.
- md5 mismatch: regenerate the specific project report outputs.
- `Missing Masking value in Summary tab for: lane N group G` — fill that cell in the workbook.
  Bypass only when the blank is intentional: `ALLOW_MISSING_MASKING=1 bash run_hpc3_container.sh`.
- `UNRESOLVABLE i7 prefix collision` from the barcode validator — mixed index lengths that no
  `BarcodeMismatchesIndex` value can separate. Pad/replace the short index in the workbook, or
  let the fqtk routing handle it (it normally does, before bcl-convert sees the sheet).
- Job OOM-killed / hit the time limit — compare `benchmarks/{rule}_{config_id}.bench` and raise
  that rule's `resources:` block in the `Snakefile`; the profile default is 8000 MB / 60 min.
  On the single-node path, raising it past the host budget has no effect: the launcher clamps
  it back down and says so. Give the machine more RAM, or accept the clamp.
- Only one job running at a time — confirm a launcher was used (they all pass
  `--workflow-profile none`); a bare `snakemake` picks up `profiles/default` and serializes.
  Expected on the single-node path for `bcl_convert` / `bcl_convert_rc` / `project_link` /
  `flexbar_project_link`, which `profiles/local` caps at `serial_operation=1` on purpose.
