#!/usr/bin/env bash
#
# Milestone 3, experiment 2 -- vary the number of HSSort MAP tasks, everything
# else fixed. Same protocol as 08-hssort-validate.sh.
#
# The map count is not set directly: Hadoop starts one map per input split, and
# -Dmapreduce.job.maps is only a hint. The input is 4 files x 250,000,000 B on
# 128 MiB blocks, so the default gives 2 splits per file = 8 maps. We move the
# split size instead (FileInputFormat: split = max(minsize, min(maxsize, block))):
#     4 maps : split.minsize = 250000000   -> one split per file
#     8 maps : default (128 MiB blocks)    -> two splits per file
#    16 maps : split.maxsize = 67108864    -> four splits per file (64 MiB)
# The real count is read back from the job log ("number of splits") and
# recorded, so a setting the input format ignores would show up immediately.
#
# Usage: ./scripts/09-hssort-validate-maps.sh <4|8|16> <reducers> [runs]
#   e.g. ./scripts/09-hssort-validate-maps.sh 16 3
#
# Rows go to logs/M3-maps-summary.tsv; full logs to logs/M3-M<m>-R<r>-run<n>-*.log.
set -euo pipefail
. "$(dirname "$0")/00-env.sh"

KIT_HOME="${KIT_HOME:-${KIT_ROOT}/TPCx-HS-Runtime-Suite}"
JAR="${KIT_HOME}/TPCx-HS-master_MR2.jar"
[ -f "${JAR}" ] || die "Missing ${JAR}"

M="${1:?usage: $0 <4|8|16> <reducers> [runs]}"
R="${2:?usage: $0 <4|8|16> <reducers> [runs]}"
RUNS="${3:-3}"
case "${M}" in
  4)  SPLIT_OPTS=(-Dmapreduce.input.fileinputformat.split.minsize=250000000) ;;
  8)  SPLIT_OPTS=() ;;
  16) SPLIT_OPTS=(-Dmapreduce.input.fileinputformat.split.maxsize=67108864) ;;
  *)  die "maps must be 4, 8 or 16 (got ${M})" ;;
esac
D="/user/$(id -un)/TPCx-HS-benchmark"
REF_CHECKSUM=21472776955442690          # HSGen counter, workload/README.md

for d in NameNode DataNode ResourceManager NodeManager; do
  "${JAVA_HOME}/bin/jps" | grep -qw "${d}" || die "${d} is not running. Run ./scripts/03-start-cluster.sh"
done
hdfs dfs -test -d "${D}/HSsort-input" || die "No input at ${D}/HSsort-input. Run ./scripts/05-hsgen.sh 1"

mkdir -p "${REPO_DIR}/logs"
SUMMARY="${REPO_DIR}/logs/M3-maps-summary.tsv"
[ -f "${SUMMARY}" ] || printf 'time\tmaps_set\tmaps_real\treducers\trun\thssort_s\thsvalidate_s\tvalidate\tsort_job\tvalidate_job\n' > "${SUMMARY}"

elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }

for run in $(seq 1 "${RUNS}"); do
  stamp="$(date +%Y%m%d-%H%M%S)"
  LOG="${REPO_DIR}/logs/M3-M${M}-R${R}-run${run}-${stamp}.log"
  hdfs dfs -rm -r -skipTrash "${D}/HSsort-output" "${D}/HSvalidate" >/dev/null 2>&1 || true

  log "maps=${M} reducers=${R}  run ${run}/${RUNS}   (log: ${LOG#${REPO_DIR}/})"
  { echo "== df before"; df -h / | tail -1; } >> "${LOG}"

  t0=$(date +%s.%N)
  echo "== HSSort" >> "${LOG}"
  hadoop jar "${JAR}" HSSort \
      -Dmapreduce.job.maps="${M}" -Dmapreduce.job.reduces="${R}" \
      -Dmapred.map.tasks="${M}"   -Dmapred.reduce.tasks="${R}" \
      ${SPLIT_OPTS[@]+"${SPLIT_OPTS[@]}"} \
      "${D}/HSsort-input" "${D}/HSsort-output" >> "${LOG}" 2>&1 \
    || die "HSSort failed -- see ${LOG}"
  t1=$(date +%s.%N)
  { echo "== df after sort"; df -h / | tail -1; } >> "${LOG}"

  echo "== HSValidate" >> "${LOG}"
  hadoop jar "${JAR}" HSValidate "${D}/HSsort-output" "${D}/HSvalidate" >> "${LOG}" 2>&1 \
    || die "HSValidate failed -- see ${LOG}"
  t2=$(date +%s.%N)

  # Judge the validate output: error lines => FAIL; empty, or a checksum equal
  # to HSGen's => PASS; anything else is shown for a human to read.
  report="$(hdfs dfs -cat "${D}/HSvalidate/part-*" 2>/dev/null || true)"
  { echo "== HSValidate output"; echo "${report}"; } >> "${LOG}"
  if echo "${report}" | grep -qiE 'misorder|bad key|error'; then
    verdict="FAIL"
  elif [ -z "$(echo "${report}" | tr -d '[:space:]')" ]; then
    verdict="PASS(empty)"
  else
    hex="$(echo "${report}" | awk 'tolower($1)=="checksum"{print tolower($2)}' | head -1)"
    if [ -n "${hex}" ] && [ "${hex}" = "$(printf '%x' "${REF_CHECKSUM}")" ]; then
      verdict="PASS(checksum)"
    else
      verdict="CHECK"
    fi
  fi

  jobs=($(grep -oE 'Running job: job_[0-9_]+' "${LOG}" | awk '{print $3}'))
  s=$(elapsed "${t0}" "${t1}"); v=$(elapsed "${t1}" "${t2}")
  # first "number of splits" line belongs to HSSort (HSValidate comes after it)
  mreal="$(grep -m1 -oE 'number of splits:[0-9]+' "${LOG}" | cut -d: -f2)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${stamp}" "${M}" "${mreal:-?}" "${R}" "${run}" "${s}" "${v}" \
         "${verdict}" "${jobs[0]:-?}" "${jobs[1]:-?}" >> "${SUMMARY}"
  [ "${mreal:-?}" = "${M}" ] || echo "  NOTE: asked for ${M} maps, Hadoop ran ${mreal:-?}"
  echo "  maps ${mreal:-?} | HSSort ${s} s | HSValidate ${v} s | ${verdict}"
  if [ "${verdict}" = "CHECK" ] || [ "${verdict}" = "FAIL" ]; then
    echo "  HSValidate output:"; echo "${report}" | head -5 | sed 's/^/    /'
  fi
done

log "Summary so far (${SUMMARY#${REPO_DIR}/})"
column -t -s $'\t' "${SUMMARY}"
