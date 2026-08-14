# HPC3 → dragen handoff

The pipeline is two workflows sharing one run directory.

| | Conversion (workflow A) | Delivery (workflow B) |
|---|---|---|
| runs on | HPC3, slurm, in the container | dragen server, locally |
| entry point | `bash run_hpc3_container.sh` | `bash run_delivery.sh` |
| Snakefile | `Snakefile` + `src/handoff.smk` | `Snakefile.delivery` + `src/delivery.smk` |
| profile | `profiles/hpc3` | `profiles/default` |
| does | bcl-convert, RC/orientation, renaming, fastp QC, plots, md5sums, read counts, undetermined analysis, flexbar/fqtk | Nextcloud share links, `occ files:scan`, link verification, order HTML/PDF reports, customer emails, external-drive rsync |
| needs | nothing but the run data and metadata workbook | `NEXTCLOUD_*` credentials, mail relay |
| ends by writing | `handoff/manifest.yaml` | share links, `Reports/order_*/`, emails |

## Why it is split

The two halves used to be one Snakefile whose Nextcloud and email rules ran in a
"disabled" mode on HPC3. Disabled did not mean skipped: `project_link` still
wrote `logs/*/project_links_*.yaml` with `link: ""`, `verify_project_links` still
wrote a `Status: SKIPPED` report, `report_order_id` still built an `index.html`
out of those empty links, and `send_order_email` still touched
`email_sent.done`. After rsyncing to the dragen server every one of those files
existed and looked up to date, so producing the real thing meant deleting or
touching them by hand.

Now those rules are simply not in the conversion workflow's DAG, so there is
nothing to invalidate. The delivery workflow starts with none of its outputs
present and builds all of them.

## The handoff directory

`handoff/` is the contract between the two. The delivery workflow parses **no**
metadata workbook, **no** SampleSheets and **no** rename maps — every value it
needs about the run was resolved once, on the conversion side, and written here.
That is also why order routing can no longer disagree between the halves.

```
handoff/
  manifest.yaml                              run-level: library, run dir, lanes, orders
  projects/{config_id}---{project}.yaml      one per deliverable project
  flexbar/{config_id}.yaml                   one per flexbar-only config
  alerts/{config_id}---{project}.json        low-reads alert payload (empty list = nothing to report)
```

A project fragment carries `order_id`, `group`, `lane`, the original metadata
project name, the paths of `md5sums.txt`, the read-counts CSV and every fastp
plot, plus a name/size inventory of the delivered FASTQs.

Fragments are written per project, as soon as that project's md5sums, read counts,
plots and low-reads check are final — not at the end of the run. The delivery
workflow globs whatever fragments are present, so links for finished projects can
be generated while the rest of the run is still converting.

`handoff/manifest.yaml` is written last, after every project. Its presence is what
distinguishes a finished conversion from one still in flight.

## Running it

**On HPC3:**

```bash
bash run_hpc3_container.sh                 # full run, ends at handoff/manifest.yaml
bash run_hpc3_container.sh handoff         # same thing, named explicitly
```

**Transfer** (from the dragen server, or push from HPC3 — `-a` to preserve mtimes,
otherwise everything looks newer than its inputs on arrival):

```bash
rsync -aP --exclude '.snakemake/' hpc3:/path/to/xR106/ /path/to/xR106/
```

**On the dragen server:**

```bash
bash run_delivery.sh --dry-run
bash run_delivery.sh
```

The delivery workflow can only *execute* on a host with Nextcloud credentials and
a mail relay. Its DAG, however, is testable anywhere — including HPC3 — with
throwaway credentials and `--dry-run`, which is enough to check that a run's
fragments produce the job set you expect before you transfer anything:

```bash
NEXTCLOUD_URL=x NEXTCLOUD_USER=u NEXTCLOUD_PASSWORD=p \
  snakemake -s Snakefile.delivery --profile profiles/default \
            --workflow-profile none --dry-run
```

`run_delivery.sh` runs `scripts/verify_handoff.py` first, which reports every gap
in one pass — missing FASTQ, missing plot, size mismatch — rather than failing on
one file at a time after some shares have already been published. Add
`--verify-md5` to re-verify every checksum against the `md5sums.txt` the
conversion side computed (slow: it reads all the data). `--skip-verify` skips the
pre-flight entirely.

Partial targets:

```bash
bash run_delivery.sh links_only     # share links + Nextcloud rescan + verification
bash run_delivery.sh reports_only   # the above plus order HTML/PDF/md5, no email
bash run_delivery.sh rsync_to_external_drive
```

## Partial runs

Both halves work on a subset of a run, but they draw the line in different places,
because a share link and an order report have different blast radii.

**Conversion side.** Any handoff fragment is an ordinary file target:

```bash
# one project
bash run_hpc3_container.sh handoff/projects/lane6---ThomL_0726I-32_xR106_L6_G1.yaml
# one lane -- also settable as `lanes: [6]` in snakemake_config_project.yaml
bash run_hpc3_container.sh $(ls handoff/projects/lane6---*.yaml)
```

`handoff/manifest.yaml` is *not* produced by a partial run: `run_handoff_manifest`
takes every project as input, so the manifest exists only when the whole run does.
That is what makes it a reliable completion signal.

**Delivery side.** What it will do depends on what has arrived:

| State of `handoff/` | Share links | Order reports | Emails |
| --- | --- | --- | --- |
| some fragments, no `manifest.yaml` | all present projects | none | none |
| some fragments + `manifest.yaml` | all present projects | orders whose projects have *all* arrived | those orders only |
| everything | all | all | all |

A share link is per project, so publishing one for a finished project while the
rest of the run is still converting is exactly what the per-project fragments are
for. An order report is per *order*, and an order can span several projects and
lanes — built from whatever fragments happen to be on disk it would silently
describe a subset, and `send_order_email` would mail that subset to the customer
as the finished delivery. So an order becomes eligible only once every project
`handoff/manifest.yaml` names for it is present; incomplete ones are named at
startup and skipped:

```
Order 0726I-32: no report or email -- still waiting on 1 piece(s) from the
conversion run: ThomL_0726I-32_xR106_L6_G1
```

Without the manifest, completeness is unknowable and no order qualifies — the run
builds links and says so. Rerun once the manifest lands; nothing needs deleting,
because a skipped order never got a sentinel.

The read-counts and low-reads emails aggregate the whole run, so they are held
back until every order has arrived, independently of any single order's state.

## Configuration

`snakemake_config.yaml` (tracked) holds the shared keys. The delivery workflow
layers `snakemake_config_project.yaml` then `snakemake_config_delivery.yaml` on
top, and `--config` overrides win over all of them.

Delivery-side settings live in `snakemake_config_delivery.yaml`
(untracked, per run directory): `nextcloud_dir_name`, `nextcloud_dir_path`,
`send_emails`, `email_sender`, `email_recipient`, `email_cc`,
`external_drive_path`.

Credentials stay in `~/.env` and never in a config file: `NEXTCLOUD_URL`,
`NEXTCLOUD_USER`, `NEXTCLOUD_PASSWORD`, `NEXTCLOUD_SSH_HOST` (optional),
`GMAIL_APP_PASSWORD`. See `.env.example`.

Two things fail fast at parse time rather than producing empty output:

- Missing Nextcloud credentials. There is no `enable_nextcloud` key any more —
  publishing is the whole point of this workflow, so a run without credentials
  could only write the empty-link stubs this split exists to eliminate.
- `send_emails: true` with an empty `email_recipient`.

`send_emails: false` is a supported review mode: links and reports are built,
nothing is mailed, and no email sentinel is created — so flipping it to `true`
later sends without anything to delete first.

## Notes

- Nothing in the delivery workflow has a producing rule for `output/`, `results/`
  or `metadata/`. Those arrive by rsync, so a missing one raises a
  `MissingInputException` naming the exact file. That is the intended
  transfer-completeness check, alongside `verify_handoff.py`.
- Target-only rules (`all`, `links_only`, `bcl_convert_only`, …) carry no
  `benchmark:` directive. Snakemake counts a benchmark file as an output, so a
  leftover `benchmarks/all.bench` from an earlier run makes the whole target look
  satisfied and the run a silent no-op.
- Low-reads alerts are detected on the conversion side (they need
  `Demultiplex_Stats.csv`) and mailed on the delivery side. The JSON payload is
  always written, with an empty `samples` list meaning "checked, nothing to
  report", so a missing payload is a real gap rather than a quiet pass.
