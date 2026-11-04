#!/usr/bin/env bash
#
# HSDataCheck -- the kit's data-presence check.
#
# The kit ships two things under this name:
#   1. HSDataCheck.sh, whose entire body is:  hdfs dfs -ls $1/*
#   2. an HSDataCheck class inside TPCx-HS-master_MR2.jar
# This script runs both so the result is traceable to the kit, and adds the
# byte-count and record-count arithmetic the kit's -ls output does not do.
#
# Usage: ./07-hsdatacheck.sh [hdfs_dir]
set -uo pipefail
. "$(dirname "$0")/00-env.sh"

KIT_HOME="${KIT_HOME:-${KIT_ROOT}/TPCx-HS-Runtime-Suite}"
. "${REPO_DIR}/conf/kit/Benchmark_Parameters.sh"
DIR="${1:-/user/${HADOOP_USER}/${HDFS_BENCHMARK_DIR}/HSsort-input}"

log "Kit HSDataCheck.sh on ${DIR}"
bash "${KIT_HOME}/HSDataCheck.sh" "${DIR}"

log "Kit HSDataCheck class"
hadoop jar "${KIT_HOME}/TPCx-HS-master_MR2.jar" HSDataCheck "${DIR}" 2>&1 | tail -15

log "Size and record accounting"
BYTES=$(hdfs dfs -du -s "${DIR}" | awk '{print $1}')
echo "  bytes            : ${BYTES}"
echo "  GiB              : $(awk -v b="${BYTES}" 'BEGIN{printf "%.3f", b/1073741824}')"
echo "  records (100 B)  : $((BYTES / 100))"
echo "  128 MB blocks    : $(awk -v b="${BYTES}" 'BEGIN{printf "%.1f", b/134217728}')"

log "Replication / block health for ${DIR}"
hdfs fsck "${DIR}" -files -blocks 2>/dev/null | tail -20
