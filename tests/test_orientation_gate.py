"""The gate between the orientation decision and barcode-bearing targets.

pick_orientation only records which orientation won; the barcodes reach
filenames through renaming_map_{config_id}_effective.csv, which a later rule
writes. Expanding targets in the window between the two names every file after
the workbook barcode — the failure these tests pin down.
"""
import os

from _helpers import REPO, Stub, load_function, load_workflow_defs_helpers

_helpers = load_workflow_defs_helpers()
effective_renaming_map_path = _helpers["effective_renaming_map_path"]

GATE_END = "# Sanitize Masking strings for filenames"
CONFIG_ID = "lane5"


def write(path, text="x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)
    return path


def paths(root):
    return (
        os.path.join(root, "results", CONFIG_ID, f"renaming_map_{CONFIG_ID}.csv"),
        os.path.join(root, "results", CONFIG_ID, f"renaming_map_{CONFIG_ID}_effective.csv"),
        os.path.join(root, "logs", CONFIG_ID, f"orientation_decision_{CONFIG_ID}.json"),
    )


def resolve(root):
    return effective_renaming_map_path(
        CONFIG_ID,
        results_base=os.path.join(root, "results"),
        logs_base=os.path.join(root, "logs"),
    )


# --- effective_renaming_map_path -------------------------------------------

def test_workbook_map_before_any_orientation_work(tmp_path):
    """A run with no RC pass at all still has to resolve to a usable map."""
    workbook, _, _ = paths(str(tmp_path))
    write(workbook)

    assert resolve(str(tmp_path)) == workbook


def test_effective_map_wins_once_written(tmp_path):
    workbook, effective, decision = paths(str(tmp_path))
    write(workbook)
    write(effective)
    write(decision, "{}")

    assert resolve(str(tmp_path)) == effective


def test_decision_without_effective_map_is_refused(tmp_path):
    """The race: silently handing back the workbook map here is the bug.

    Between pick_orientation and generate_effective_renaming_map the decision
    exists and the map does not. Returning the workbook map names an RC
    project's targets after barcodes bcl-convert never demultiplexed with.
    """
    workbook, _, decision = paths(str(tmp_path))
    write(workbook)
    write(decision, '{"AcmeC_WGS_8plex": "rc_i5"}')

    try:
        resolved = resolve(str(tmp_path))
    except RuntimeError as raised:
        assert "await_orientation_decision" in str(raised)
    else:
        raise AssertionError(
            f"expected a refusal, got the workbook map back: {resolved}")


# --- await_orientation_decision --------------------------------------------

def load_gate(checkpoints):
    return load_function("src/workflow_defs.smk", "await_orientation_decision",
                         GATE_END, {"checkpoints": checkpoints})


class RecordingCheckpoint:
    def __init__(self, calls, name):
        self.calls = calls
        self.name = name

    def get(self, **wildcards):
        self.calls.append((self.name, wildcards))


def test_gate_waits_on_the_effective_map_not_the_decision():
    calls = []
    checkpoints = Stub(
        pick_orientation=RecordingCheckpoint(calls, "pick_orientation"),
        generate_effective_renaming_map=RecordingCheckpoint(
            calls, "generate_effective_renaming_map"),
    )

    load_gate(checkpoints)(CONFIG_ID)

    assert calls == [("generate_effective_renaming_map", {"config_id": CONFIG_ID})]


def test_gate_falls_back_to_pick_orientation():
    """A workflow without the later checkpoint still gets the earlier gate."""
    calls = []
    checkpoints = Stub(pick_orientation=RecordingCheckpoint(calls, "pick_orientation"))

    load_gate(checkpoints)(CONFIG_ID)

    assert calls == [("pick_orientation", {"config_id": CONFIG_ID})]


def test_gate_no_ops_outside_a_workflow():
    load_function("src/workflow_defs.smk", "await_orientation_decision",
                  GATE_END)(CONFIG_ID)


# --- what the shipped workflow declares ------------------------------------

def snakefile():
    with open(os.path.join(REPO, "Snakefile")) as handle:
        return handle.read()


def test_effective_map_rule_is_a_checkpoint():
    assert "checkpoint generate_effective_renaming_map:" in snakefile()


def test_fastp_sample_declares_the_map_it_reads():
    """Its params/resources reach a checkpoint, so the rule must take it as input.

    Snakemake rejects a params function that touches an undeclared checkpoint,
    and every spawned Slurm job rebuilds the DAG — so omitting this fails each
    fastp job remotely even when the driver's own DAG is past the checkpoint.
    """
    source = snakefile()
    start = source.index("rule fastp_sample:")
    inputs = source[start:source.index("    output:", start)]

    assert "renaming_map_{config_id}_effective.csv" in inputs
