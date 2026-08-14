slurm account comes from $SLURM_ACCOUNT (set it in ~/.env); never pin one in profiles/hpc3/config.yaml or any other tracked file — the launchers hard-fail when it is unset, on purpose

the whole workflow runs inside one container, snakemake driver included: `bash run_hpc3_container.sh`
that launcher runs snakemake in the image and binds the host slurm client in; spawned jobs re-enter the image via the generated .container/bin/python shim
never add a `container:` directive or use-singularity to a rule — rules are already in the container and would nest
pixi.toml + pixi.lock stay the single dependency spec; the image installs them with --locked. change a version there, `pixi lock`, copy both to the container repo, rebuild
`pixi run ...` / run_hpc3.sh remain the host fallback path for development
don't use python venv
HPC3 uses singularity (module load singularity), not DRAGEN; slurm executor via profiles/hpc3

two workflows, one run directory — see docs/handoff.md
conversion (`Snakefile` + src/handoff.smk, HPC3): bcl-convert through md5sums/QC, ends by writing handoff/manifest.yaml
delivery (`Snakefile.delivery` + src/delivery.smk, dragen server via `bash run_delivery.sh`): nextcloud links, order reports, emails
never add a nextcloud/email/share rule to the conversion Snakefile — a rule that "skips" still writes its outputs, and after the rsync those stubs look up to date, which is the hand-touching this split removed
the delivery side must not parse metadata workbooks or SampleSheets; if it needs a value, add it to a handoff fragment in src/handoff.smk
partial runs: share links are per project and publish as soon as a fragment lands; order reports and emails wait until every project handoff/manifest.yaml names for that order has arrived — never widen that to "whatever fragments are on disk", it mails customers a partial delivery
B only executes where nextcloud creds + a mail relay exist, but its DAG dry-runs anywhere with throwaway NEXTCLOUD_* vars
no `benchmark:` on target-only rules (all, links_only, bcl_convert_only, …) — snakemake counts the benchmark file as an output, so a leftover one makes the target a silent no-op
