use sbsandme_lab slurm account 
the whole workflow runs inside one container, snakemake driver included: `bash run_hpc3_container.sh`
that launcher runs snakemake in the image and binds the host slurm client in; spawned jobs re-enter the image via the generated .container/bin/python shim
never add a `container:` directive or use-singularity to a rule — rules are already in the container and would nest
pixi.toml + pixi.lock stay the single dependency spec; the image installs them with --locked. change a version there, `pixi lock`, copy both to the container repo, rebuild
`pixi run ...` / run_hpc3.sh remain the host fallback path for development
single-node/no-slurm path: profiles/local + run_local_container.sh (run_local.sh where there's no singularity); it sizes snakemake to the host via scripts/local_resources.sh and clamps rules whose mem_mb exceeds the box. profiles/hpc3 + run_hpc3*.sh stay the slurm path — don't merge them
don't use python venv
HPC3 uses singularity (module load singularity), not DRAGEN; slurm executor via profiles/hpc3
