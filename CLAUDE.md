use pixi for python/tool provisioning (pixi.toml + pixi.lock); run commands with `pixi run ...`
the legacy mamba env `bcl_convert` is being retired in favor of pixi
don't use python venv
HPC3 uses singularity (module load singularity), not DRAGEN; bcl-convert runs via profiles/hpc3 (slurm executor)
