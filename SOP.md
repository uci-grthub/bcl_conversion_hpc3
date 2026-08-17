# SOP: Run the BCL Conversion Snakemake Workflow (HPC3)

Supports **MiSeq i100** and **NovaSeqX** — the platform is auto-detected from the metadata
workbook. The whole workflow runs inside a Singularity container — every tool and the
Snakemake driver itself — launched by `run_hpc3_container.sh` (slurm executor,
`profiles/hpc3`). There is no DRAGEN instrument involved on HPC3.

`module load singularity` is the only host requirement. The pre-run steps need no pixi
either: `scripts/init_run.sh` is plain bash, and anything that needs the image's python
or snakemake outside a workflow run goes through `scripts/container_exec.sh <command>`,
which uses the same image and binds as the launcher.

`pixi run` remains the host fallback path (`run_hpc3.sh`), for development or if the
image is unavailable. Every command below is given in its container form; the pixi
equivalent is the same command with `bash scripts/container_exec.sh` replaced by
`pixi run`.

## Quickstart (a normal run)

```bash
# 1. Clone into a run-named directory and enter it
cd /path/to/your/runs          # e.g. /dfs9/ucightf-lab/$USER/runs
git clone https://github.com/uci-grthub/bcl_conversion_hpc3 {RUN_NAME}
cd {RUN_NAME}

# 2. Copy the lab's SampleSheet .xlsx into metadata/ (REQUIRED before init:
#    init_run.sh reads whatever .xlsx is there to fill in metadata and library_name)
cp /path/to/{RUN_NAME}.xlsx metadata/

# 3. Set up the run: creates snakemake_config_project.yaml and prefills
#    metadata / library_name / data_dir from the newest run in the HPC3 staging dir
#    Plain bash (find/sed/cp only) — no pixi and no container required
bash scripts/init_run.sh      # or: bash scripts/init_run.sh --staging-dir /dfs3b/ucightf_lab/NSRaw

# 4. Confirm the prefilled config
$EDITOR snakemake_config_project.yaml         # confirm data_dir, library_name, metadata

# 5. Validate metadata + preview the plan (no processing happens)
module load singularity
bash scripts/container_exec.sh python run_validation.py
bash run_hpc3_container.sh --dryrun

# 6. Run the full workflow (singularity + slurm via profiles/hpc3)
bash run_hpc3_container.sh
```

That is the HPC3 half. It ends by writing `handoff/manifest.yaml`, and needs no
`.env`: this workflow has no Nextcloud or email rules at all.

Delivery — share links, order reports and customer emails — is a separate workflow
on the dragen server, because it needs a Nextcloud instance and a mail relay.

```bash
# 7. Transfer the run to the delivery host. Copy these flags verbatim; see the
#    notes below for what each one prevents.
rsync -aWP --no-g \
    --exclude '.snakemake/' \
    --exclude '.container/' \
    --exclude 'snakemake_config_delivery.yaml' \
    --exclude 'project_link*' \
    --exclude 'flexbar_project_link*' \
    --exclude 'verify_project_link*' \
    --exclude 'nextcloud_scan*' \
    --exclude 'rescan_nextcloud*' \
    --exclude 'Reports/' \
    ./ {DELIVERY_HOST}:/staging/nextcloud/testing_illumina/NovaSeqX/{RUN_NAME}/

# 8. On the delivery host, set up the delivery config. The first run creates it
#    from the tracked template and stops so you can review it.
ssh {DELIVERY_HOST}
cd /staging/nextcloud/testing_illumina/NovaSeqX/{RUN_NAME}
bash run_delivery.sh --dry-run                 # creates snakemake_config_delivery.yaml, exits
$EDITOR snakemake_config_delivery.yaml         # send_emails, email_sender/recipient/cc

# 9. Preview, then publish. With send_emails: false this builds every share link
#    and order report and mails nobody — the intended review state.
bash run_delivery.sh --dry-run
bash run_delivery.sh

# 10. Confirm Nextcloud actually indexed the files. Errors must be 0 and Files
#    non-zero; this is the one failure the workflow cannot detect for you.
grep -h '^| [0-9]' logs/*/rescan_nextcloud_*.log

# 11. Only once the reports look right: set send_emails: true and re-run to mail
#     the customers. Nothing needs deleting first — no sentinel was written.
```

Three things about step 7 that are easy to get wrong, each of which fails *silently*
— every rule still reports success:

- **`--no-g`.** Nextcloud serves the files over SMB as an account in the delivery
  host's group. Without this, rsync preserves HPC3's group instead and every share
  link resolves to an empty folder.
- **The `*link*` / `Reports/` exclusions.** A run directory predating the
  conversion/delivery split still holds the old skip-stubs; transferred over, they
  satisfy `project_link` and `report_order_id` and the empty links get published.
- **`snakemake_config_delivery.yaml`.** Untracked but not transfer-ignored, so a
  copy made on HPC3 overwrites the delivery host's own and suppresses the step 8
  review prompt.

For a large run, submit step 7 as a batch job rather than running it on a login
node — a few hundred GB will be throttled or killed there. Compute nodes have
`/dfs9` and outbound ssh. See [docs/handoff.md](docs/handoff.md) for the full
reference, including partial-run behaviour and how to recover a transfer that
landed with the wrong group.

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
ls /dfs9/ucightf-lab/containers/bcl_convert_docker_v2.sif        # need the container
```

- **Group `ucightf`** — `/dfs9/ucightf-lab` (container, lab scratch) is `drwxrws---`.
- **Group `ucightf_lab_share`** — `/dfs3b/ucightf_lab/NSRaw` (BCL staging) likewise.
- **A slurm account, in `$SLURM_ACCOUNT`.** No account is pinned in the repo — the
  launcher refuses to submit until you set one, because slurm would otherwise
  charge your personal default association. Set it once:
  `echo 'SLURM_ACCOUNT=<your_account>' >> ~/.env` (works for every run directory
  you clone, and on the cron path).
- Run has finished copying (a `CopyComplete.txt` exists in the run directory under
  `/dfs3b/ucightf_lab/NSRaw/...`).
- A SampleSheet `.xlsx` from the lab, **copied into `metadata/` before `init_run.sh`**
  (quickstart step 2) — that is the file `init_run.sh` reads to fill in `metadata` and
  `library_name`.
- **Singularity** available via `module load singularity`. The only host requirement
  for a run.
- **The container.** Not in the repo. Lives at
  `/dfs9/ucightf-lab/containers/bcl_convert_docker_v2.sif`, readable by group
  `ucightf`, named by `container_sif` in `snakemake_config.yaml`. Nothing to configure.
  It holds every tool *and* the Snakemake driver.
- **pixi** — *not* required. Only for the host fallback path (`run_hpc3.sh`) and
  development: `curl -fsSL https://pixi.sh/install.sh | bash`, then `pixi install`.
  See [README.md](README.md#container-image) for how the image is built.

---

## Reference

### Credentials (`.env`) — not used on HPC3

The conversion workflow needs no credentials: it has no Nextcloud or email rules.
These are read only by the delivery workflow on the dragen server
(`bash run_delivery.sh`, see [docs/handoff.md](docs/handoff.md)), which hard-fails
at parse time if the Nextcloud ones are missing:

| Variable | What it is |
| --- | --- |
| `NEXTCLOUD_URL` | Nextcloud instance, e.g. `https://precision.biochem.uci.edu` |
| `NEXTCLOUD_USER` | Nextcloud **API** account owning the share directory |
| `NEXTCLOUD_PASSWORD` | **App password** for that account (not the login password) |
| `NEXTCLOUD_SSH_USER` | *Optional.* Login for `occ files:scan` over ssh. Defaults to the OS user running the workflow |
| `NEXTCLOUD_SSH_HOST` | *Optional.* Full `user@host` (or ssh_config alias), overriding both of the above for ssh |
| `GMAIL_APP_PASSWORD` | App password for the `email_sender` account |

`NEXTCLOUD_USER` and the ssh login are **not** the same thing. The first is a
Nextcloud API account — often a shared service user with no Unix account on the
Nextcloud host and no authorized key there. `rescan_nextcloud` ssh's to that host
to run `occ files:scan`, and it does so as the OS user by default. Set
`NEXTCLOUD_SSH_USER` only when that is wrong; if the run stops at a password
prompt for `<api-user>@<host>`, this is why.

Email addresses are **not** environment variables. `email_sender` /
`email_recipient` / `email_cc` are config keys in
`snakemake_config_delivery.yaml`; an `EMAIL_SENDER` exported in `~/.env` is
ignored. Only `GMAIL_APP_PASSWORD` is read from the environment, and it must be
the app password for whatever `email_sender` names.

Credentials live in **`~/.env`** — written once, reused by every run directory you
clone, and outside every repo so they cannot be committed by accident:

```bash
cp .env.example ~/.env && chmod 600 ~/.env
$EDITOR ~/.env
```

`run_hpc3_container.sh`, `scripts/container_exec.sh` and `pixi run` all source it
(`scripts/load_dotenv.sh`), then layer a run-local `./.env` on top if one exists — use
that only when a single run needs different credentials than your usual ones. On the
container path the environment is inherited into the image and then carried to the
compute nodes by SLURM's `--export=ALL`, so sourcing once at launch covers every rule.
Generate a Nextcloud app password under **Settings > Personal > Security > Devices &
sessions > Create new app password**.

Verify access before relying on it:

```bash
bash scripts/container_exec.sh python scripts/test_nextcloud_token.py
```

### Configuration files

- `snakemake_config_project.yaml` — per-run overrides (gitignored).
  `bash scripts/init_run.sh` prefills `library_name`, `metadata`, `data_dir`; plus optional
  `external_drive_path`, `scratch_dir`, `tiles`, `flexbar_bin`.
- `snakemake_config.yaml` — base defaults, layered under the project file. Rarely edited.
- `snakemake_config_delivery.yaml` — delivery-side only, read on the dragen server:
  `send_emails`, `email_sender` / `email_recipient` / `email_cc`,
  `nextcloud_dir_name` / `nextcloud_dir_path`, `external_drive_path`. Untracked and
  per run directory; `run_delivery.sh` creates it from the tracked
  `snakemake_config_delivery.yaml.example` on first use and stops for review.
  Nothing on HPC3 reads it. See [docs/handoff.md](docs/handoff.md).
- `profiles/hpc3/config.yaml` — the HPC3 executor profile: slurm executor,
  `standard` partition, account from `$SLURM_ACCOUNT` (never pinned in the file),
  `cores: 32` (must stay >= the largest rule `threads:`), up to 32 concurrent jobs,
  `keep-going`, `latency-wait: 120` (dfs9 is slow to expose outputs), `rerun-triggers: mtime`
  (an unrelated Snakefile edit won't re-run bcl-convert), and 8000 MB / 60 min defaults.
  Used automatically by `run_hpc3_container.sh`. Heavy rules override these in the `Snakefile`:
  `bcl_convert`/`bcl_convert_rc` 24 threads / 48 GB, `flexbar_per_config` 32 / 64 GB / 480 min,
  `fqtk_per_config` 8 / 16 GB / 480 min.
- `profiles/default/config.yaml` — non-HPC3 resource-limit profile (kept for parity with
  upstream / single-host use); not used by `run_hpc3_container.sh`, which passes
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
bash run_hpc3_container.sh results/lane2/fqtk_lane2.done
cat logs/lane2/fqtk_lane2.log                        # resolved barcodes + thresholds
cat metadata/fqtk_barcodes_lane2_resolved.tsv        # full-length barcodes and decoys
```

Details in [README.md](README.md#fqtk-post-hoc-demultiplexing).

### Run specific stages

Configs are per lane (`lane1`…`lane8`; MiSeq uses only `lane1`). Pass the target straight
to `run_hpc3_container.sh` — it already carries the profile, the submission flags and the
compute-node shim, so this is the form to reach for:

```bash
bash run_hpc3_container.sh output/lane1                    # BCL conversion, one lane
bash run_hpc3_container.sh results/fastp_lane1.done
bash run_hpc3_container.sh Reports/order_0626I-08/index.html
bash run_hpc3_container.sh results/{RUN}-count.csv
bash run_hpc3_container.sh -R compile_read_counts          # force a rule to re-run
```

For a small target it is sometimes quicker to skip SLURM and run it in the foreground.
That needs `--workflow-profile none` explicitly, or `profiles/default` is auto-merged and
serializes everything (see Troubleshooting):

```bash
bash scripts/container_exec.sh snakemake --workflow-profile none --cores 4 \
    results/fastp_lane1.done
```

The host fallback path is the same command as `pixi run snakemake ...`.

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
bash scripts/container_exec.sh sh -c 'snakemake --rulegraph | dot -Tpng' > rulegraph.png
bash scripts/container_exec.sh sh -c 'snakemake --dag | dot -Tpdf'      > dag.pdf
```

Both `snakemake` and `dot` are in the image, so the pipe belongs inside it — hence the
`sh -c`. The host-env equivalents are `pixi run rulegraph` / `pixi run dag`.

### Troubleshooting quick checks

- Missing lanes: confirm `data_dir` and detected lanes in the dry run.
- BCL conversion failures: check the Singularity module/image, and slurm job logs.
- `bcl_convert_docker_v2.sif: No such file or directory` — you are almost certainly not in group
  `ucightf` (`id | grep ucightf`); the image is there, the directory is just unreadable
  to you. Ask RCIC or the PI to add you.
- `Error: SLURM_ACCOUNT is not set` / `sbatch: error: Invalid account` — list your
  accounts with `sacctmgr -nP show assoc user=$USER format=Account`, then
  `echo 'SLURM_ACCOUNT=<your_account>' >> ~/.env` and rerun.
- Container cannot see your files (`No such file or directory` on a path that exists) —
  your working directory or `data_dir` is on a filesystem outside the container binds
  (`/dfs3b`, `/dfs9`). Add it to `CONTAINER_DATA_BINDS` in `scripts/container_binds.sh`,
  or work under one of those.
- Empty reports: verify metadata sheet names and headers.
- md5 mismatch: regenerate the specific project report outputs.
- `Missing Masking value in Summary tab for: lane N group G` — fill that cell in the workbook.
  Bypass only when the blank is intentional: `ALLOW_MISSING_MASKING=1 bash run_hpc3_container.sh`.
- `UNRESOLVABLE i7 prefix collision` from the barcode validator — mixed index lengths that no
  `BarcodeMismatchesIndex` value can separate. Pad/replace the short index in the workbook, or
  let the fqtk routing handle it (it normally does, before bcl-convert sees the sheet).
- Job OOM-killed / hit the time limit — compare `benchmarks/{rule}_{config_id}.bench` and raise
  that rule's `resources:` block in the `Snakefile`; the profile default is 8000 MB / 60 min.
- Only one job running at a time — confirm `run_hpc3_container.sh` was used (it passes
  `--workflow-profile none`); a bare `snakemake` picks up `profiles/default` and serializes.
