slurm account comes from $SLURM_ACCOUNT (set it in ~/.env); never pin one in profiles/hpc3/config.yaml or any other tracked file — the launchers hard-fail when it is unset, on purpose

the whole workflow runs inside one container, snakemake driver included: `bash run_hpc3_container.sh`
that launcher runs snakemake in the image and binds the host slurm client in; spawned jobs re-enter the image via the generated .container/bin/python shim
never add a `container:` directive or use-singularity to a rule — rules are already in the container and would nest
pixi.toml + pixi.lock stay the single dependency spec; the image installs them with --locked. change a version there, `pixi lock`, copy both to the container repo, rebuild
`pixi run ...` / run_hpc3.sh remain the host fallback path for development
don't use python venv
HPC3 uses singularity (module load singularity), not DRAGEN; slurm executor via profiles/hpc3
