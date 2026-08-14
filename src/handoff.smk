# Handoff manifest emission (conversion side / workflow A).
#
# The conversion workflow runs on HPC3, where there is no Nextcloud instance and
# no mail relay.  Rather than let the delivery rules run in a "skipped" mode that
# still writes empty-link YAMLs and stub reports -- which then look up-to-date
# after an rsync and have to be hand-deleted on the delivery host -- workflow A
# does not contain the delivery rules at all.  It instead serializes every piece
# of parse-time state the delivery workflow needs into `handoff/`.
#
# Layout:
#   handoff/manifest.yaml                       run-level: library, lanes, orders
#   handoff/projects/{config_id}---{project}.yaml   one per deliverable project
#   handoff/flexbar/{config_id}.yaml            one per flexbar-only config
#   handoff/alerts/{config_id}---{project}.json low-reads alert payloads
#
# A project fragment is written as soon as that project's md5sums, read counts
# and plots are final, so the delivery host can start generating share links for
# finished projects while the rest of the run is still converting.
#
# Invariant: the delivery workflow parses NO metadata and NO SampleSheets.  If a
# delivery rule needs a value, it must appear here.

# HANDOFF_DIR is defined in the Snakefile, before `rule all` needs it.

# Fragment file names use `---` between config_id and project, matching the
# existing project_links_{config}---{project}.yaml convention.  Project names may
# contain underscores but never `/` or `---`.
def handoff_fragment(config_id, project):
    return f"{HANDOFF_DIR}/projects/{config_id}---{project}.yaml"


def _handoff_lane_for_config(config_id):
    m = re.match(r'lane(\d+)', str(config_id))
    return int(m.group(1)) if m else None


def _handoff_order_id(config_id, project):
    """Resolve order_id for a renamed project folder.

    Mirrors the (lane, group) preference the old project_link params lambda used:
    a `_G{n}` suffix on the folder name is authoritative, because duplicate
    project names on one lane each get their own group and PROJECT_ORDER_ID keeps
    only the last-written entry for the shared (project, lane) key.
    """
    lane = _handoff_lane_for_config(config_id)
    grp_m = re.search(r'_G(\d+)$', project)
    if lane is not None and grp_m:
        oid = ORDER_ID_LOOKUP.get((lane, int(grp_m.group(1))))
        if oid:
            return oid
    orig = PROJECT_RENAME_MAP_INV.get((config_id, project), project)
    return PROJECT_ORDER_ID.get((orig, lane if lane is not None else 0), "")


def _handoff_group(config_id, project):
    m = re.search(r'_G(\d+)$', project)
    if m:
        return m.group(1)
    orig = PROJECT_RENAME_MAP_INV.get((config_id, project), project)
    return get_project_group(orig, config_id)


def _handoff_kind(config_id):
    if config_id in FLEXBAR_CONFIGS:
        return "flexbar"
    if config_id in FQTK_CONFIGS:
        return "fqtk"
    return "bcl"


def _handoff_fastq_inventory(fastq_dir):
    """Size-and-name inventory of the delivered FASTQs.

    The delivery host uses this to verify the rsync landed everything before it
    publishes a share link; md5s are already in the project's md5sums.txt, so
    only sizes are recorded here (a stat, not a re-read of every file).
    """
    entries = []
    for path in sorted(glob.glob(os.path.join(fastq_dir, "*.fastq.gz"))):
        try:
            entries.append({"name": os.path.basename(path),
                            "bytes": os.path.getsize(path)})
        except OSError:
            entries.append({"name": os.path.basename(path), "bytes": None})
    return entries


def build_handoff_entry(config_id, project):
    """Everything the delivery workflow needs about one deliverable project."""
    order_id = _handoff_order_id(config_id, project)
    orig_project = PROJECT_RENAME_MAP_INV.get((config_id, project), project)
    fastq_dir = f"output/{config_id}/{project}"

    # get_project_plot_targets scans every config; keep only this one's plots so
    # a project split across lanes gets one fragment per lane.
    plot_targets = [
        p for p in get_project_plot_targets(project, lane_filter=None,
                                            order_id=order_id or None)
        if p.startswith(f"results/{config_id}/")
    ]

    return {
        "config_id": config_id,
        "project": project,
        "orig_project": orig_project,
        "order_id": str(order_id),
        "group": str(_handoff_group(config_id, project)),
        "lane": _handoff_lane_for_config(config_id),
        "kind": _handoff_kind(config_id),
        "fastq_dir": fastq_dir,
        "md5_file": f"{fastq_dir}/md5sums.txt",
        "read_counts": f"results/{config_id}/{project}/read_counts_{project}.csv",
        "plots_dir": f"results/{config_id}/{project}",
        "plot_targets": sorted(plot_targets),
        "fastqs": _handoff_fastq_inventory(fastq_dir),
    }


rule project_handoff_manifest:
    """Freeze one project's delivery metadata once its data products are final.

    Inputs are exactly the artifacts the delivery side consumes, so a fragment
    can never advertise a project whose md5s, counts or plots are still moving.
    """
    input:
        md5 = "output/{config_id}/{project}/md5sums.txt",
        counts = "results/{config_id}/{project}/read_counts_{project}.csv",
        plots_copied = "output/{config_id}/{project}/.plots_copied",
        # The alert payload rather than the .low_reads_checked sentinel: the
        # delivery side reads the payload, and requesting the sentinel alone lets
        # a fragment ship for a project whose payload was never written.
        low_reads = "handoff/alerts/{config_id}---{project}.json",
    output:
        fragment = "handoff/projects/{config_id}---{project}.yaml"
    log:
        "logs/{config_id}/project_handoff_manifest_{config_id}---{project}.log"
    wildcard_constraints:
        config_id = "[^/]+",
        project = ".+"
    run:
        entry = build_handoff_entry(wildcards.config_id, wildcards.project)
        if not entry["order_id"].strip():
            raise RuntimeError(
                f"Missing order_id for {wildcards.config_id}/{wildcards.project}; "
                "the delivery workflow cannot route this project to an order. "
                "Check the metadata order-id mapping for this project/lane."
            )
        os.makedirs(os.path.dirname(output.fragment), exist_ok=True)
        with atomic_output(output.fragment) as fh:
            yaml.dump(entry, fh, default_flow_style=False, sort_keys=True)
        with open(log[0], "w") as lf:
            lf.write(f"order_id={entry['order_id']} group={entry['group']} "
                     f"fastqs={len(entry['fastqs'])} plots={len(entry['plot_targets'])}\n")


rule flexbar_handoff_manifest:
    """Fragment for a flexbar config whose shared directory is the raw flexbar
    output rather than a renamed project directory."""
    input:
        done = "results/{config_id}/flexbar_{config_id}.done"
    output:
        fragment = "handoff/flexbar/{config_id}.yaml"
    wildcard_constraints:
        config_id = "[^/]+"
    run:
        order_id = FLEXBAR_ORDER_ID_MAP.get(wildcards.config_id, "")
        entry = {
            "config_id": wildcards.config_id,
            "order_id": str(order_id),
            "project": FLEXBAR_ORDER_ID_PROJECT.get(wildcards.config_id, "flexbar"),
            "share_dir": f"output/{wildcards.config_id}/flexbar",
            # collect_flexbar_report_extras rewrites sample names in the barcode
            # and filesize tables; carry the mapping rows so the delivery host
            # does not have to re-read the metadata workbook to rebuild it.
            "renaming_rows": [
                {k: (str(v) if v is not None else "") for k, v in row.items()}
                for row in FLEXBAR_CONFIG_RENAMING_MAP.get(wildcards.config_id, [])
            ],
        }
        os.makedirs(os.path.dirname(output.fragment), exist_ok=True)
        with atomic_output(output.fragment) as fh:
            yaml.dump(entry, fh, default_flow_style=False, sort_keys=True)


rule run_handoff_manifest:
    """Run-level manifest: written last, so its presence means conversion is complete.

    The delivery workflow reads the per-project fragments directly and can run
    against a partial set; this file exists so an operator (and verify_handoff.py)
    can tell a finished run from an in-flight one.
    """
    input:
        fragments = [handoff_fragment(c, p) for c, p in CONFIG_PROJECT_PAIRS],
        flexbar = expand("handoff/flexbar/{config_id}.yaml", config_id=FLEXBAR_CONFIGS),
        counts = f"results/{LIBRARY}-count.csv",
    output:
        manifest = f"{HANDOFF_DIR}/manifest.yaml"
    run:
        import datetime, subprocess as _sp

        try:
            _rev = _sp.run(["git", "rev-parse", "HEAD"], capture_output=True,
                           text=True, cwd=workflow.basedir).stdout.strip()
        except OSError:
            _rev = ""

        orders = {}
        for _c, _p in CONFIG_PROJECT_PAIRS:
            _oid = str(_handoff_order_id(_c, _p))
            _entry = orders.setdefault(_oid, {"projects": [], "lanes": [],
                                              "flexbar_configs": []})
            if _p not in _entry["projects"]:
                _entry["projects"].append(_p)
            _lane = _handoff_lane_for_config(_c)
            if _lane is not None and _lane not in _entry["lanes"]:
                _entry["lanes"].append(_lane)
        for _cfg, _oid in FLEXBAR_ORDER_ID_MAP.items():
            _entry = orders.setdefault(str(_oid), {"projects": [], "lanes": [],
                                                   "flexbar_configs": []})
            if _cfg not in _entry["flexbar_configs"]:
                _entry["flexbar_configs"].append(_cfg)
        for _entry in orders.values():
            _entry["projects"].sort()
            _entry["lanes"].sort()
            _entry["flexbar_configs"].sort()

        manifest = {
            "schema_version": 1,
            "library": LIBRARY,
            "run_dir": DATA_DIR,
            "lanes": list(detected_lanes),
            "config_ids": list(CONFIG_IDS),
            "orders": orders,
            "counts_csv": f"results/{LIBRARY}-count.csv",
            "validation_xlsx": VALIDATION_XLSX or "",
            "generated_at": datetime.datetime.now().astimezone().isoformat(),
            "workflow_commit": _rev,
        }
        os.makedirs(os.path.dirname(output.manifest) or ".", exist_ok=True)
        with atomic_output(output.manifest) as fh:
            yaml.dump(manifest, fh, default_flow_style=False, sort_keys=True)


rule handoff:
    """Convenience target: everything the delivery host needs to be rsynced."""
    input:
        f"{HANDOFF_DIR}/manifest.yaml"
