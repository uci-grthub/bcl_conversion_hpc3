The current architecture is: conda env → Snakemake → SLURM → Singularity containers per rule.

Yes, it's technically possible, but there are real tradeoffs on SLURM/HPC systems.

The core challenge is that if Snakemake itself runs inside a container, it then needs to either:

Submit SLURM jobs from inside the container — requires bind-mounting SLURM binaries, munge auth socket, and SLURM config dirs into the container. This works on some clusters where admins allow it, but is fragile and often restricted. On HPC3 it may not be permitted.

Run rules locally inside the container — drop executor: slurm and use executor: local. All rules run serially or with limited parallelism inside one container. You lose SLURM scheduling entirely, which for a BCL-convert + demux workflow means much slower wall time.

Nested Singularity — if the Snakemake container then tries to launch per-rule Singularity containers (your current use-singularity: true), you hit nested container issues. Apptainer supports some forms of this (e.g., with --fakeroot), but it's complex and often disabled on shared HPC.

Why the current setup is actually the standard HPC pattern:

The conda env for Snakemake + per-rule Singularity is exactly what the Snakemake docs recommend for HPC. The orchestrator doesn't need to be containerized because:

The Snakefile's Python env (pandas, yaml) is pinned in the conda env
All the actual science tools are already containerized per rule
SLURM scheduling works cleanly from the host
If reproducibility of the Snakemake env itself is the concern, the lighter solution is pinning the conda env with a lockfile (conda env export --no-builds > environment.lock.yml) and tracking that in git — same guarantee as a container without the SLURM integration headache.

If you want full containerization without SLURM, the architecture shift would be to Kubernetes + Snakemake's k8s executor, or a platform like Nextflow Tower — but that's a significant rewrite.

Short answer: the current conda-orchestrates-SLURM-with-containers pattern is the right call for HPC3 and isn't worth changing.