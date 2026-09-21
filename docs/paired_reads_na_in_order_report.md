# Bug: every "Paired Reads" cell reads N/A in the delivered order report

**Runs affected:** xR114, xR115 (order `0926I-13` in both) · **Date of analysis:** 2026-09-21

## Symptom

The per-order HTML report mailed to the customer shows `N/A` in the **Paired Reads**
column for every sample — 144 of 144 in both runs. Barcode, Type, R1/R2 size and the
md5sums are all correct; only the read count is missing.

Nothing failed. Every rule reported success, `verify_handoff.py` said `Handoff OK`, and
the emails went out.

## Root cause

`src/generate_report.py` takes the per-sample read count from bcl-convert's
`output/{config_id}/Reports/Demultiplex_Stats.csv`:

```python
demux_csv = os.path.join(output_base_dir, config_id, "Reports", "Demultiplex_Stats.csv")
```

On the delivery host that file did not exist for any lane — `output/lane1/` held only the
project directory and `Logs/`. With the cache empty, the lookup falls through to:

```python
paired_reads = demux_reads if (demux_reads is not None and demux_reads > 0) else "N/A"
```

The file was missing because `scripts/transfer_to_delivery.sh` excluded it:

```bash
--exclude 'Reports/'      # the bug
```

**An rsync pattern with no internal `/` matches that basename at any depth.** The trailing
slash restricts the match to directories; it does not anchor it. The intent was the run's
own top-level `Reports/` — the order reports, which the delivery host rebuilds and which
must not arrive pre-made and looking up to date. What it actually matched was *every*
directory named `Reports`, including all eight `output/lane*/Reports/` from bcl-convert.

The transfer log shows it plainly: the sibling `output/lane1/Logs/` transferred, its
`Reports/` never appears in the file list.

This is the same basename trap the script already documents for `logs/*link*`, in the
opposite direction: there a pattern was too narrow to match, here one was too broad.

## Why nothing caught it

`get_project_demux_stats()` exists in `src/workflow_defs.smk` and returns exactly these
paths — but nothing references it. No rule declares `Demultiplex_Stats.csv` as an input,
so its absence costs no rule a failure. The report generator then degrades silently: a
missing stats file and a genuinely unassigned sample produce the same `N/A`.

## The fix

Three changes, applied to both run directories:

1. **`scripts/transfer_to_delivery.sh`** — anchor the exclusion to the transfer root:

   ```bash
   --exclude '/Reports/'
   ```

   A leading slash anchors the pattern to the root of the transfer, so it matches the
   run's own `Reports/` and nothing nested. Verify any change to the pattern list with
   `bash scripts/transfer_to_delivery.sh --list-excluded <dest>` rather than assuming it
   bit.

2. **`src/generate_report.py`** — warn when the stats file is absent instead of quietly
   emitting `N/A`, and name the likely cause (the rsync dropped
   `output/{config_id}/Reports/`).

3. **`scripts/verify_handoff.py`** — check `output/{config_id}/Reports/Demultiplex_Stats.csv`
   for every config_id in the handoff, alongside the FASTQ and plot checks. This is the
   pre-flight gate that should have caught it: it runs before any share link is published
   and before anything is mailed.

## Recovering a run already delivered with N/A

Pull just the missing directories from the conversion host, then rebuild the report and
resend:

```bash
rsync -aP --no-g --include='*/' --include='Reports/***' --exclude='*' \
  hpc3:/dfs3b/ucightf_lab/NSProcessed/<RUN>/output/ \
  <delivery-run-dir>/output/

rm Reports/order_<ORDER>/index.html Reports/order_<ORDER>/email_sent.done
bash run_delivery.sh
```

Deleting `email_sent.done` is what makes the email send again — the sentinel is the only
record that it already went. The customer has the N/A version, so say so in the mail.

## Rule of thumb

An rsync exclusion for a path you mean literally gets a leading slash. Without one you
are excluding a *name*, and this repo has several names that recur at more than one depth
(`Reports`, `Logs`, `logs`). Excluding data is silent on both sides: rsync reports
success, and the delivery workflow builds a report around whatever arrived.
