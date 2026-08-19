"""Every SLURM binary the executor plugin shells out to must be bound in.

The image ships no slurm packages, so a binary the plugin calls and the bind
list omits does not fail at startup — it fails at submission, once per job,
with a bare "[Errno 2] No such file or directory: '<binary>'". sacctmgr was
missed once and sshare a second time; this reads both lists instead.
"""
import os
import re

from _helpers import REPO

# Names that are plausibly a SLURM client call. Matched against the plugin
# source, then filtered to what actually exists on this host, so a site whose
# slurm build lacks one of them does not fail the test.
SLURM_BINARIES = ("sacct", "sacctmgr", "sattach", "sbatch", "scancel",
                  "scontrol", "sinfo", "squeue", "srun", "sshare", "sstat")


def bound_binaries():
    """The /usr/bin entries in CONTAINER_SLURM_BINDS."""
    with open(os.path.join(REPO, "scripts", "container_binds.sh")) as handle:
        source = handle.read()
    block = source[source.index("CONTAINER_SLURM_BINDS=("):]
    block = block[:block.index(")")]
    return {os.path.basename(line.strip()) for line in block.splitlines()
            if line.strip().startswith("/usr/bin/")}


def plugin_dirs():
    dirs = []
    for module in ("snakemake_executor_plugin_slurm",
                   "snakemake_executor_plugin_slurm_jobstep"):
        try:
            imported = __import__(module)
        except ImportError:
            continue
        dirs.append(os.path.dirname(imported.__file__))
    return dirs


def binaries_the_plugin_calls():
    pattern = re.compile(r"\b(%s)\b" % "|".join(SLURM_BINARIES))
    called = set()
    for directory in plugin_dirs():
        for name in os.listdir(directory):
            if not name.endswith(".py"):
                continue
            with open(os.path.join(directory, name)) as handle:
                called.update(pattern.findall(handle.read()))
    return called


def test_bind_list_covers_every_binary_the_plugin_calls():
    called = binaries_the_plugin_calls()
    if not called:
        # Ran outside the pipeline environment; the plugin source is what this
        # checks against, so there is nothing to compare.
        return

    present = {b for b in called if os.path.exists(os.path.join("/usr/bin", b))}
    missing = present - bound_binaries()

    assert not missing, (
        f"scripts/container_binds.sh does not bind {sorted(missing)}; the plugin "
        f"calls them and the image has no slurm packages")


def test_account_validation_binaries_are_both_bound():
    """validate_account() falls back from sacctmgr to sshare, so both are load-bearing.

    On HPC3 sacctmgr cannot reach slurmdbd from the compute nodes and returns
    empty, which is exactly the path that then calls sshare.
    """
    assert {"sacctmgr", "sshare"} <= bound_binaries()
