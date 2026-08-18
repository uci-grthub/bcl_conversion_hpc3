# shellcheck shell=bash
#
# Sample sheets must be regenerated BEFORE the real DAG is built, not as part
# of it.
#
# `generate_samplesheets` rewrites results/<cfg>/SampleSheet_<cfg>.csv when the
# metadata workbook changed, and when the new sheet's content hash differs from
# the old one it deletes the validation artifacts that sheet invalidated:
#
#   results/<cfg>/SampleSheet_<cfg>_validated.csv
#   logs/<cfg>/barcode_hamming_validation_<cfg>.{done,txt}
#
# That deletion happens while the rule runs, which is long after Snakemake
# froze the DAG. So in a single pass the DAG is built while the stale validated
# sheet still exists -- validate_barcode_hamming_distances is judged up to date
# and pruned -- and bcl_convert is then submitted against a file the earlier
# job deleted out from under it. That is the failure in
# .snakemake/log/2026-08-18T153328.790103.snakemake.log: bcl_convert retried
# four times, each time with its validated sheet already gone.
#
# The fix is ordering, not dependency: `ancient()` on the validation rule's
# samplesheet input has to stay. Without it, any mtime bump on the workbook --
# a re-save with identical content is enough -- would rewrite the validated
# sheet, rerun bcl_convert, and bcl_convert deletes .output/<cfg>/*.fastq.gz
# before reconverting. The rule's hash comparison is what keeps that keyed to
# real content changes; it just has to run first.
#
# Hence a pre-pass: run generate_samplesheets to completion in its own
# invocation, let it purge, then build the real DAG against what is actually on
# disk.
SAMPLESHEET_PREPASS_ARGS=(--until generate_samplesheets)

# False for invocations that inspect or repair state rather than run the
# workflow; a pre-pass would either be meaningless or actively wrong there
# (--touch, for one, would stamp the sheets as current without generating
# them).
samplesheet_prepass_wanted() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --unlock|--touch|--dag|--rulegraph|--filegraph|--d3dag|\
            --report|--report-*|--summary|--detailed-summary|--list*|\
            --cleanup*|--delete-*|--archive|--containerize|-h|--help|--version)
                return 1
                ;;
        esac
    done
    return 0
}
