# SOP: Run the BCL Conversion Snakemake Workflow (HPC3)

Supports **MiSeq i100** and **NovaSeqX** — the platform is auto-detected from the metadata
workbook. `pixi run` auto-loads `.env` and provisions the Python/CLI environment, so
day-to-day commands take no extra flags. bcl-convert itself runs inside a Singularity
container via `run_hpc3.sh` (slurm executor, `profiles/hpc3`) — there is no DRAGEN
instrument involved on HPC3.

## Quickstart (a normal run)

```bash
# 1. Clone into a run-named directory and enter it
cd /dfs9/ucightf-lab/kstachel/test_bcl
git clone https://github.com/whtns/grthub_bclconvert {RUN_NAME}
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

### Prerequisites

- Run has finished copying (a `CopyComplete.txt` exists in the run directory under
  `/dfs3b/ucightf_lab/NSRaw/...`).
- A SampleSheet `.xlsx` from the lab, placed in `metadata/`.
- **pixi** installed once: `curl -fsSL https://pixi.sh/install.sh | bash`, then
  `pixi install` to build the environment from `pixi.lock`.
- **Singularity** available via `module load singularity` (already wired into the rules
  that need it); the bcl-convert container image path is set in the Snakefile / profile.

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

Copy `.env.example` to `.env` and fill in; `pixi run` sources it automatically
(`scripts/load_dotenv.sh`). Generate a Nextcloud app password under **Settings >
Personal > Security > Devices & sessions > Create new app password**.

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
  enabled, resource defaults. Used automatically by `run_hpc3.sh`.
- `profiles/default/config.yaml` — non-HPC3 resource-limit profile (kept for parity with
  upstream / single-host use); not used by `run_hpc3.sh`.

### Metadata format (auto-detected)

- **NovaSeqX** (has a `Summary` sheet):
  - Summary sheet (header row 3): `Lane`, `Gr` (Group), `Project Name`, `Masking`, `Fastq Link`
  - Per-project sheets: `Lane`, `Group`, `Sample Name`, `i7 Barcode Sequence`, `i5 Barcode Sequence`
  - Masking strings must match the run cycle structure in `RunInfo.xml`.
- **MiSeq i100** (has a `Barcode Entries` sheet, no `Summary` sheet):
  - Per-sample barcodes; Order IDs inferred from the `Lab ID` column; all samples in `lane1`.

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
- Empty reports: verify metadata sheet names and headers.
- md5 mismatch: regenerate the specific project report outputs.
