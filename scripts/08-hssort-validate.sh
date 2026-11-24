#!/usr/bin/env bash
#
# Milestone 3 -- HSSort then HSValidate, timed, following the protocol in
# workload/RESULTS.md (clean output dirs before each run, N runs per setting).
#
# Command lines are the kit's own (TPCx-HS-master.sh:265 and :299).
#
# Usage: ./scripts/08-hssort-validate.sh <reducers> [runs]     (runs default 3)
#   e.g. ./scripts/08-hssort-validate.sh 4
#
# Every run appends one row to logs/M3-summary.tsv and keeps its full Hadoop
# output (job counters included) in logs/M3-R<r>-run<n>-<time>.log.
set -euo pipefail
. "$(dirname "$0")/00-env.sh"

KIT_HOME="${KIT_HOME:-${KIT_ROOT}/TPCx-HS-Runtime-Suite}"
JAR="${KIT_HOME}/TPCx-HS-master_MR2.jar"
[ -f "${JAR}" ] || die "Missing ${JAR}"

R="${1:?usage: $0 <reducers> [runs]}"
RUNS="${2:-3}"
D="/user/$(id -un)/TPCx-HS-benchmark"
REF_CHECKSUM=21472776955442690          # HSGen counter, workload/README.md

for d in NameNode DataNode ResourceManager NodeManager; do
  "${JAVA_HOME}/bin/jps" | grep -qw "${d}" || die "${d} is not running. Run ./scripts/03-start-cluster.sh"
done
hdfs dfs -test -d "${D}/HSsort-input" || die "No input at ${D}/HSsort-input. Run ./scripts/05-hsgen.sh 1"

mkdir -p "${REPO_DIR}/logs"
SUMMARY="${REPO_DIR}/logs/M3-summary.tsv"
[ -f "${SUMMARY}" ] || printf 'time\treducers\trun\thssort_s\thsvalidate_s\tvalidate\tsort_job\tvalidate_job\n' > "${SUMMARY}"

elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }

for run in $(seq 1 "${RUNS}"); do
  stamp="$(date +%Y%m%d-%H%M%S)"
  LOG="${REPO_DIR}/logs/M3-R${R}-run${run}-${stamp}.log"
  hdfs dfs -rm -r -skipTrash "${D}/HSsort-output" "${D}/HSvalidate" >/dev/null 2>&1 || true

  log "reducers=${R}  run ${run}/${RUNS}   (log: ${LOG#${REPO_DIR}/})"
  { echo "== df before"; df -h / | tail -1; } >> "${LOG}"

  t0=$(date +%s.%N)
  echo "== HSSort" >> "${LOG}"
  hadoop jar "${JAR}" HSSort \
      -Dmapreduce.job.maps=4 -Dmapreduce.job.reduces="${R}" \
      -Dmapred.map.tasks=4   -Dmapred.reduce.tasks="${R}" \
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${stamp}" "${R}" "${run}" "${s}" "${v}" \
         "${verdict}" "${jobs[0]:-?}" "${jobs[1]:-?}" >> "${SUMMARY}"
  echo "  HSSort ${s} s | HSValidate ${v} s | ${verdict}"
  if [ "${verdict}" = "CHECK" ] || [ "${verdict}" = "FAIL" ]; then
    echo "  HSValidate output:"; echo "${report}" | head -5 | sed 's/^/    /'
  fi
done

log "Summary so far (${SUMMARY#${REPO_DIR}/})"
column -t -s $'\t' "${SUMMARY}"
