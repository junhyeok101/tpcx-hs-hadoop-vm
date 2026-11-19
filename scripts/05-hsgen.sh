#!/usr/bin/env bash
#
# HSGen -- TPCx-HS data generation, using the official kit's HSGen class.
#
# Invocation is copied verbatim from the kit driver (TPCx-HS-master.sh:232):
#
#   hadoop jar $HSSORT_JAR HSGen \
#       -Dmapreduce.job.maps=$NUM_MAPS -Dmapreduce.job.reduces=$NUM_REDUCERS \
#       -Dmapred.map.tasks=$NUM_MAPS   -Dmapred.reduce.tasks=$NUM_REDUCERS   \
#       $hssize /user/$HADOOP_USER/$HDFS_BENCHMARK_DIR/HSsort-input
#
# HSGen's first argument is a RECORD COUNT, not a byte count. A record is
# 100 bytes (HSInputFormat.java:55-57 -> KEY_LENGTH 10 + VALUE_LENGTH 90), so
#   records = GB * 10,000,000
# HSGen is map-only: HSGen.java:300 calls job.setNumReduceTasks(0), so
# NUM_REDUCERS has no effect here (it matters for HSSort in Milestone 3).
#
# Why this script, and not ./TPCx-HS-master.sh -m -g 1 :
#   1. The driver's smallest scale factor (-g 1) is 10^9 records = 100 GB.
#      This VM has ~10 GB of HDFS capacity. No -g option fits.
#   2. The driver runs the FULL suite (HSGen -> HSSort -> HSValidate) twice,
#      which is Milestone 3 scope, not Milestone 2.
#   3. The driver opens each run with
#         hadoop fs -rm -r -skipTrash /user/$HADOOP_USER/$HDFS_BENCHMARK_DIR/*
#      i.e. it destroys existing data without asking.
#   4. The driver wraps HDFS setup in "sudo -u $HDFS_USER", and sudo on this
#      VM requires a password.
# Calling the kit's HSGen class directly keeps the exact benchmark code path
# while staying inside Milestone 2 and inside the disk budget.
#
# Usage: ./05-hsgen.sh [size_in_GB]     (default 1)
set -euo pipefail
. "$(dirname "$0")/00-env.sh"

KIT_HOME="${KIT_HOME:-${KIT_ROOT}/TPCx-HS-Runtime-Suite}"
PARAMS="${REPO_DIR}/conf/kit/Benchmark_Parameters.sh"

[ -d "${KIT_HOME}" ] || die "Kit not found at ${KIT_HOME}."
[ -f "${PARAMS}"  ] || die "Missing ${PARAMS}"
# shellcheck source=/dev/null
. "${PARAMS}"

HSSORT_JAR="${KIT_HOME}/TPCx-HS-master_MR2.jar"   # MR2 = Hadoop 2+/3 API
[ -f "${HSSORT_JAR}" ] || die "Missing ${HSSORT_JAR}"

SIZE_GB="${1:-1}"
RECORDS=$(awk -v g="${SIZE_GB}" 'BEGIN{printf "%.0f", g*10000000}')
OUT="/user/${HADOOP_USER}/${HDFS_BENCHMARK_DIR}/HSsort-input"

log "HSGen: ${SIZE_GB} GB = ${RECORDS} records x 100 B  ->  ${OUT}"
echo "  kit      : ${KIT_HOME} (v$(cat "${KIT_HOME}/VERSION.txt" 2>/dev/null || echo '?'))"
echo "  jar      : $(basename "${HSSORT_JAR}")"
echo "  NUM_MAPS : ${NUM_MAPS}"

# ---- disk guard: Milestone 3's HSSort needs ~3x the input ------------------
AVAIL_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
NEED_GB=$(awk -v g="${SIZE_GB}" 'BEGIN{printf "%.0f", g*3+2}')
echo "  free on /: ${AVAIL_GB} GB ; need ~${NEED_GB} GB (3x input + 2 GB headroom)"
[ "${AVAIL_GB}" -ge "${NEED_GB}" ] || die "Not enough free disk for a ${SIZE_GB} GB dataset."

# ---- never clobber an existing dataset ------------------------------------
if hdfs dfs -test -d "${OUT}" 2>/dev/null; then
  die "${OUT} already exists. Delete it yourself if you mean to replace it:
       hdfs dfs -rm -r -skipTrash ${OUT}"
fi
hdfs dfs -mkdir -p "/user/${HADOOP_USER}/${HDFS_BENCHMARK_DIR}"

mkdir -p "${REPO_DIR}/logs"
LOG="${REPO_DIR}/logs/HSGen-${SIZE_GB}GB-$(date +%Y%m%d-%H%M%S).log"

log "Running HSGen (log: ${LOG})"
# Exactly the kit's command line, with the kit's parameters.
{ time hadoop jar "${HSSORT_JAR}" HSGen \
    -Dmapreduce.job.maps="${NUM_MAPS}" \
    -Dmapreduce.job.reduces="${NUM_REDUCERS}" \
    -Dmapred.map.tasks="${NUM_MAPS}" \
    -Dmapred.reduce.tasks="${NUM_REDUCERS}" \
    "${RECORDS}" "${OUT}" ; } 2>&1 | tee "${LOG}"

log "HSGen output"
hdfs dfs -ls "${OUT}"
echo
hdfs dfs -du -h -s "${OUT}"
log "Elapsed (from the 'real' line above)"
grep -E "^real" "${LOG}" || true
