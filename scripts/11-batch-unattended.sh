#!/usr/bin/env bash
#
# Milestone 3 -- unattended batch, ~25-30 min. Start it and walk away.
#
#   1. reducer 7 re-measured           3 runs   (11/21 runs 2-3 were disturbed)
#   2. reducer 1                       3 runs   (completes the 1..7 curve)
#   3. map count 4 / 8 / 16, reducer 3 3 runs each, round-robin
#      (M8-R3 is the same setting as the 11/21 reducer-3 runs: a drift check)
#   4. per-phase breakdown of every M3 log, then all tables
#
# Each HSSort+HSValidate pair (normally ~100 s) runs under a time limit. If one
# hangs -- as on 11/21 -- the batch kills it, restarts the cluster, records
# TIMEOUT and moves on, so one stuck run cannot eat the whole lunch break.
#
# Start it detached, so closing VS Code does not kill it:
#   setsid nohup ./scripts/11-batch-unattended.sh > /dev/null 2>&1 &
#   tail -f logs/batch-latest.log          # watch (Ctrl+C stops watching only)
# Preview the plan without running anything:
#   DRY=1 ./scripts/11-batch-unattended.sh
set -uo pipefail                 # no -e: a failed run must not stop the batch
. "$(dirname "$0")/00-env.sh"

S="${REPO_DIR}/scripts"
RUN_TIMEOUT="${RUN_TIMEOUT:-480}"     # seconds per pair; normal is ~100
D="/user/$(id -un)/TPCx-HS-benchmark"

PLAN=()
for i in 1 2 3; do PLAN+=("R7|08-hssort-validate.sh 7 1"); done
for i in 1 2 3; do PLAN+=("R1|08-hssort-validate.sh 1 1"); done
for i in 1 2 3; do for m in 4 8 16; do PLAN+=("M${m}-R3|09-hssort-validate-maps.sh ${m} 3 1"); done; done

if [ "${DRY:-0}" = 1 ]; then
  echo "${#PLAN[@]} runs, ~$(( ${#PLAN[@]} * 105 / 60 )) min if nothing hangs:"
  for p in "${PLAN[@]}"; do echo "  ${p%%|*}  ->  scripts/${p#*|}"; done
  exit 0
fi

for f in 08-hssort-validate.sh 09-hssort-validate-maps.sh 10-phase-breakdown.sh; do
  [ -f "${S}/${f}" ] || die "scripts/${f} is missing -- copy it into scripts/ first"
  chmod +x "${S}/${f}"
done

mkdir -p "${REPO_DIR}/logs"
BLOG="${REPO_DIR}/logs/batch-$(date +%Y%m%d-%H%M%S).log"
ln -sfn "$(basename "${BLOG}")" "${REPO_DIR}/logs/batch-latest.log"
exec > >(tee -a "${BLOG}") 2>&1

snapshot() { echo "  [$(date +%T)] $1: $(free -h | awk '/^Mem/{print "mem used "$3", avail "$7}; /^Swap/{print "swap "$3}' | paste -sd' ' -) | disk $(df -h / | awk 'NR==2{print $4" free"}')"; }

cluster_ok() {
  for d in NameNode DataNode ResourceManager NodeManager SecondaryNameNode; do
    "${JAVA_HOME}/bin/jps" | grep -qw "${d}" || return 1
  done
  timeout 60 hdfs dfs -test -d "${D}/HSsort-input"
}

restart_cluster() {
  log "Restarting cluster"
  for a in $(timeout 60 yarn application -list 2>/dev/null | awk '/^application_/{print $1}'); do
    timeout 60 yarn application -kill "${a}" || true
  done
  timeout 180 "${S}/04-stop-cluster.sh" || true
  pkill -f 'org.apache.hadoop' 2>/dev/null || true; sleep 3
  timeout 300 "${S}/03-start-cluster.sh"
}

log "Batch start: ${#PLAN[@]} runs, time limit ${RUN_TIMEOUT} s each  (log: logs/$(basename "${BLOG}"))"
snapshot "start"
if ! cluster_ok; then
  restart_cluster || die "Cluster does not come up -- check ./scripts/03-start-cluster.sh by hand"
  cluster_ok || die "Cluster up but HSsort-input missing -- run ./scripts/05-hsgen.sh 1"
fi

i=0; ok=0; bad=0
for p in "${PLAN[@]}"; do
  i=$((i+1)); label="${p%%|*}"; cmd="${p#*|}"
  log "[${i}/${#PLAN[@]}] ${label}"
  # shellcheck disable=SC2086
  timeout -k 15 "${RUN_TIMEOUT}" "${S}/"${cmd}
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    ok=$((ok+1))
  else
    bad=$((bad+1))
    [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ] && echo "  TIMEOUT after ${RUN_TIMEOUT} s: ${label}" || echo "  FAILED (exit ${rc}): ${label}"
    echo -e "$(date +%Y%m%d-%H%M%S)\t${label}\tTIMEOUT_OR_FAIL\trc=${rc}" >> "${REPO_DIR}/logs/batch-failures.tsv"
  fi
  snapshot "after"
  # After a timeout the job (and its hadoop client) may still be alive, so
  # always restart; otherwise only when the cluster looks unhealthy.
  if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ] || ! cluster_ok; then
    restart_cluster || { echo "  cluster restart failed -- stopping batch"; break; }
  fi
done

log "Runs: ${ok} ok, ${bad} failed/timed out"
log "Reducer experiment (logs/M3-summary.tsv)"
column -t -s $'\t' "${REPO_DIR}/logs/M3-summary.tsv" 2>/dev/null | cut -c1-110
log "Map experiment (logs/M3-maps-summary.tsv)"
column -t -s $'\t' "${REPO_DIR}/logs/M3-maps-summary.tsv" 2>/dev/null | cut -c1-120
log "Per-phase breakdown"
"${S}/10-phase-breakdown.sh"
log "Batch done"
