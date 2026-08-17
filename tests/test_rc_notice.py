"""The operator-facing RC notice: the summary CSV and the email subject tag.

The manager needs to know an i5 reverse-complement workflow ran for a project at
the time reports go out, so he can add his own wording for the client. Nothing
here may change what the client reads.

The two halves live in different workflows: the conversion run writes
handoff/rc_orientation_summary.csv (run level), and the delivery run tags each
order's subject from that order's handoff fragments — never from the run-level
summary, which would make one order's email wait on another order's lanes.
"""
import json
import os

import pandas as pd
import yaml

from _helpers import (FIXTURE_DUAL_PROJECT, FIXTURE_MAP, FIXTURE_ORDER_ID, Stub,
                      load_function, load_rule_body, load_workflow_defs_helpers)

apply_orientation_to_map = load_workflow_defs_helpers()["apply_orientation_to_map"]


def _handoff_entries_for_order(order_id):
    """Same fragment read Snakefile.delivery performs at parse time."""
    import glob
    entries = []
    for path in sorted(glob.glob("handoff/projects/*.yaml")):
        with open(path) as handle:
            entry = yaml.safe_load(handle) or {}
        if str(entry.get("order_id", "")) == str(order_id):
            entries.append(entry)
    return entries


rc_orientation_tag = load_function(
    "src/delivery.smk", "rc_orientation_tag", end_marker="rule send_order_email:",
    extra_globals={"handoff_entries_for_order": _handoff_entries_for_order})
SUMMARY_BODY = load_rule_body("rc_orientation_summary",
                              end_marker="rule update_validation_workbook:")
# What the conversion run stamps on each project's handoff fragment.
handoff_orientation = load_function("src/handoff.smk", "_handoff_orientation",
                                   end_marker="def build_handoff_entry(")

SUMMARY_COLUMNS = ["order_id", "config_id", "project", "group", "orientation",
                   "workbook_i7", "delivered_i7", "workbook_i5", "delivered_i5",
                   "rc_fraction", "n_samples"]


def write_fragments(root, entries):
    """One handoff fragment per (order_id, orientation) pair, as conversion writes them."""
    os.makedirs(os.path.join(root, "handoff", "projects"), exist_ok=True)
    for index, (order_id, orientation) in enumerate(entries):
        entry = {"config_id": "lane5", "project": f"P{index}", "order_id": order_id,
                 "orientation": orientation}
        with open(os.path.join(root, "handoff", "projects",
                               f"lane5---P{index}.yaml"), "w") as handle:
            yaml.dump(entry, handle)


def in_dir(path, func):
    previous = os.getcwd()
    os.chdir(path)
    try:
        return func()
    finally:
        os.chdir(previous)


# --- subject tag ------------------------------------------------------------

def test_tag_is_empty_without_any_fragment(tmp_path):
    assert in_dir(str(tmp_path), lambda: rc_orientation_tag(FIXTURE_ORDER_ID)) == ""


def test_tag_is_empty_when_no_project_was_flipped(tmp_path):
    write_fragments(str(tmp_path), [(FIXTURE_ORDER_ID, "original")])
    assert in_dir(str(tmp_path), lambda: rc_orientation_tag(FIXTURE_ORDER_ID)) == ""


def test_tag_names_the_flipped_index(tmp_path):
    write_fragments(str(tmp_path), [
        ("0626I-49", "rc_i5"),
        ("0726I-08", "rc_i7"),
        ("0726I-30", "rc_both"),
        ("0726I-44", "rc_i5"),
        ("0726I-44", "rc_i7"),   # one order, two projects, two flavours
    ])
    expected = {
        "0626I-49": " [i5 reverse-complement applied]",
        "0726I-08": " [i7 reverse-complement applied]",
        "0726I-30": " [i7+i5 reverse-complement applied]",
        "0726I-44": " [i7+i5 reverse-complement applied]",
        "0626I-25": "",   # an order with no RC project stays untagged
    }
    got = in_dir(str(tmp_path),
                 lambda: {order: rc_orientation_tag(order) for order in expected})
    assert got == expected


# --- summary CSV ------------------------------------------------------------

def build_run(root, decisions):
    """A run root with an effective map, decision and candidates per lane."""
    original = pd.read_csv(FIXTURE_MAP, dtype=str, keep_default_na=False)
    for config_id, decision in decisions.items():
        os.makedirs(os.path.join(root, "results", config_id), exist_ok=True)
        os.makedirs(os.path.join(root, "logs", config_id), exist_ok=True)
        apply_orientation_to_map(original, decision).to_csv(
            os.path.join(root, "results", config_id,
                         f"renaming_map_{config_id}_effective.csv"), index=False)
        with open(os.path.join(root, "logs", config_id,
                               f"orientation_decision_{config_id}.json"), "w") as handle:
            json.dump(decision, handle)
        candidates = [{"config_id": config_id, "project": project,
                       "expected_pair": "CGCTCATT+AGGCGAAG", "total_hits": 5000,
                       "rc_hits": 4800, "rc_fraction": 0.96,
                       "fix_type": orientation.replace("rc_", "") + "_rc"}
                      for project, orientation in decision.items()]
        with open(os.path.join(root, "logs", config_id,
                               f"rc_candidates_{config_id}.json"), "w") as handle:
            json.dump(candidates, handle)
    os.makedirs(os.path.join(root, "handoff"), exist_ok=True)


def run_summary_rule(root, config_ids, order_lookup):
    namespace = {
        "os": os, "pd": pd,
        "CONFIG_IDS": config_ids,
        "ORDER_ID_LOOKUP": order_lookup,
        "input": Stub(
            decisions=[f"logs/{c}/orientation_decision_{c}.json" for c in config_ids],
            candidates=[f"logs/{c}/rc_candidates_{c}.json" for c in config_ids],
            maps=[f"results/{c}/renaming_map_{c}_effective.csv" for c in config_ids]),
        "output": Stub(csv="handoff/rc_orientation_summary.csv"),
        "log": ["logs/rc_orientation_summary.log"],
    }
    in_dir(root, lambda: exec(SUMMARY_BODY, namespace))
    return pd.read_csv(os.path.join(root, "handoff", "rc_orientation_summary.csv"),
                       dtype=str, keep_default_na=False)


def test_summary_lists_only_flipped_projects(tmp_path):
    root = str(tmp_path)
    build_run(root, {"lane5": {FIXTURE_DUAL_PROJECT: "rc_i5"}, "lane6": {}})

    frame = run_summary_rule(root, ["lane5", "lane6"],
                             {(5, 1): FIXTURE_ORDER_ID, (5, 2): "0626I-57"})

    assert list(frame.columns) == SUMMARY_COLUMNS
    assert len(frame) == 1, "the clean lane must contribute no rows"
    row = frame.iloc[0]
    assert row["config_id"] == "lane5"
    assert row["project"] == FIXTURE_DUAL_PROJECT
    assert row["orientation"] == "rc_i5"
    assert row["order_id"] == FIXTURE_ORDER_ID
    assert row["group"] == "1"
    assert row["n_samples"] == "3"
    assert row["rc_fraction"] == "0.9600"
    assert row["workbook_i7"] == row["delivered_i7"] == "CGCTCATT"
    assert row["workbook_i5"] == "AGGCGAAG"
    assert row["delivered_i5"] == "CTTCGCCT"


def test_summary_is_empty_when_nothing_was_flipped(tmp_path):
    root = str(tmp_path)
    build_run(root, {"lane5": {}})

    frame = run_summary_rule(root, ["lane5"], {(5, 1): FIXTURE_ORDER_ID})

    assert frame.empty
    assert list(frame.columns) == SUMMARY_COLUMNS, "header must survive an empty run"


def test_effective_map_feeds_the_subject_tag(tmp_path):
    """End to end across the handoff: the orientation the conversion run stamped on
    the effective map is what the delivery run's email subject reports."""
    root = str(tmp_path)
    build_run(root, {"lane5": {FIXTURE_DUAL_PROJECT: "rc_both"}})

    orientation = in_dir(root, lambda: handoff_orientation("lane5", FIXTURE_DUAL_PROJECT))
    assert orientation["orientation"] == "rc_both"
    assert orientation["workbook_i5"] == "AGGCGAAG"
    assert orientation["delivered_i5"] == "CTTCGCCT"

    write_fragments(root, [(FIXTURE_ORDER_ID, orientation["orientation"])])
    assert in_dir(root, lambda: rc_orientation_tag(FIXTURE_ORDER_ID)) \
        == " [i7+i5 reverse-complement applied]"
    assert in_dir(root, lambda: rc_orientation_tag("0999I-99")) == ""
