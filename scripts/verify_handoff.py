#!/usr/bin/env python3
"""Check that a run directory rsynced from the conversion host is complete.

Run this on the delivery host before `snakemake -s Snakefile.delivery`.  Snakemake
itself will fail on the first missing input, one file at a time; this reports every
gap in one pass, which is what you want after a transfer that may have been
interrupted.

    python3 scripts/verify_handoff.py            # existence + size check
    python3 scripts/verify_handoff.py --md5      # also re-verify every checksum

Exit status is 0 when the handoff is complete, 1 otherwise.
"""

import argparse
import glob
import hashlib
import os
import sys

import yaml

HANDOFF_DIR = "handoff"


def _load(path):
    with open(path) as fh:
        return yaml.safe_load(fh) or {}


def _md5(path, chunk=8 * 1024 * 1024):
    digest = hashlib.md5()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(chunk), b""):
            digest.update(block)
    return digest.hexdigest()


def check_entry(entry, problems, check_md5):
    label = f"{entry['config_id']}/{entry['project']}"

    for key in ("md5_file", "read_counts"):
        path = entry.get(key)
        if path and not os.path.exists(path):
            problems.append(f"{label}: missing {key} {path}")

    for plot in entry.get("plot_targets", []):
        if not os.path.exists(plot):
            problems.append(f"{label}: missing plot {plot}")

    # Size mismatches are the signature of a transfer killed mid-file: rsync
    # leaves a short file behind, and every downstream check that only tests
    # existence passes anyway.
    expected_md5 = {}
    md5_path = entry.get("md5_file")
    if check_md5 and md5_path and os.path.exists(md5_path):
        with open(md5_path) as fh:
            for line in fh:
                parts = line.split(None, 1)
                if len(parts) == 2:
                    expected_md5[os.path.basename(parts[1].strip())] = parts[0]

    for record in entry.get("fastqs", []):
        path = os.path.join(entry["fastq_dir"], record["name"])
        if not os.path.exists(path):
            problems.append(f"{label}: missing fastq {path}")
            continue
        expected_bytes = record.get("bytes")
        actual_bytes = os.path.getsize(path)
        if expected_bytes is not None and actual_bytes != expected_bytes:
            problems.append(
                f"{label}: size mismatch {path} "
                f"(expected {expected_bytes:,}, got {actual_bytes:,})"
            )
            continue
        if check_md5:
            want = expected_md5.get(record["name"])
            if want is None:
                problems.append(f"{label}: {record['name']} absent from {md5_path}")
            elif _md5(path) != want:
                problems.append(f"{label}: md5 mismatch {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--md5", action="store_true",
                        help="re-verify every FASTQ checksum (slow; reads all data)")
    args = parser.parse_args()

    problems = []

    manifest_path = os.path.join(HANDOFF_DIR, "manifest.yaml")
    if not os.path.exists(manifest_path):
        print(f"note: {manifest_path} absent -- the conversion run is either "
              "incomplete or still in flight; checking the fragments that exist.",
              file=sys.stderr)
        manifest = {}
    else:
        manifest = _load(manifest_path)

    fragments = sorted(glob.glob(os.path.join(HANDOFF_DIR, "projects", "*.yaml")))
    if not fragments:
        print(f"error: no fragments under {HANDOFF_DIR}/projects/", file=sys.stderr)
        return 1

    entries = [_load(f) for f in fragments]
    for entry in entries:
        check_entry(entry, problems, args.md5)

    # The run manifest lists what a complete conversion produced; a fragment named
    # there but absent here means the rsync dropped a whole project.
    expected_projects = {
        p for order in manifest.get("orders", {}).values()
        for p in order.get("projects", [])
    }
    present_projects = {e["project"] for e in entries}
    for missing in sorted(expected_projects - present_projects):
        problems.append(f"manifest lists project {missing} but no fragment is present")

    counts_csv = manifest.get("counts_csv")
    if counts_csv and not os.path.exists(counts_csv):
        problems.append(f"missing run-level read counts {counts_csv}")

    for flexbar_frag in sorted(glob.glob(os.path.join(HANDOFF_DIR, "flexbar", "*.yaml"))):
        entry = _load(flexbar_frag)
        config_id = entry.get("config_id", "?")
        for path in (f"metadata/flexbar_barcodes_{config_id}.txt",
                     f"output/{config_id}/flexbar/size.txt",
                     f"output/{config_id}/flexbar/flexbarOut.log"):
            if not os.path.exists(path):
                problems.append(f"flexbar {config_id}: missing {path}")

    n_fastqs = sum(len(e.get("fastqs", [])) for e in entries)
    if problems:
        print(f"Handoff INCOMPLETE: {len(problems)} problem(s) across "
              f"{len(entries)} project(s):")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(f"Handoff OK: {len(entries)} project(s), {n_fastqs} FASTQ(s)"
          + (", checksums verified" if args.md5 else ", sizes verified"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
