#!/usr/bin/env bash
#
# Milestone 3 -- scalability test, unattended (~1 h 45 min). Start it and walk away.
#
# A. Data scaling  (scale-up): 1 -> 2 -> 4 -> 8 GB, best setting from the
#    performance analysis (3 reducers, one map per 128 MB split), YARN pool
#    unchanged (3840 MB). Question: does time grow in proportion to data?
#    HSGen is timed at every size too.
# B. Resource scaling (strong scaling): 2 GB fixed, YARN pool 0.5x / 1x / 2x
#    (1920 / 3840 / 7680 MB), reducers = reducer slots of that pool (1 / 3 / 6).
#    A stand-in, on one host, for adding nodes. Question: twice the containers,
#    twice as fast? The 1x point is the 2 GB run of part A.
#
# Order: 1 GB -> 2 GB -> resource runs at 2 GB -> 4 GB -> 8 GB -> regenerate the
# original 1 GB dataset (checksum must be 21472776955442690 again).
#
# Every HSSort+HSValidate pair has a time limit that scales with the work; a
# hung pair is killed, the cluster restarted, TIMEOUT recorded, and the batch
# moves on. The YARN config is backed up first and ALWAYS restored on exit.
#
# Start detached (survives closing VS Code), then watch:
#   setsid nohup ./scripts/12-scalability-batch.sh > logs/scale-start.err 2>&1 &
#   sleep 3; tail -f logs/scale-latest.log
# Preview only:   DRY=1 ./scripts/12-scalability-batch.sh
# Options (env):  SIZES="1 2 4 8"  RES=1 (0 skips part B)  RUNS=3
set -uo pipefail
. "$(dirname "$0")/00-env.sh"

S="${REPO_DIR}/scripts"
SIZES="${SIZES:-1 2 4 8}"
RES="${RES:-1}"
RUNS="${RUNS:-3}"
R_BEST=3
POOL_BASE=3840
RES_SIZE=2
declare -A RES_REDUCERS=([1920]=1 [7680]=6)       # reducer slots: (pool-768)/1024
declare -A RES_VCORES=([1920]=2 [3840]=4 [7680]=8)
REF_1G=21472776955442690

KIT_HOME="${KIT_HOME:-${KIT_ROOT}/TPCx-HS-Runtime-Suite}"
JAR="${KIT_HOME}/TPCx-HS-master_MR2.jar"
D="/user/$(id -un)/TPCx-HS-benchmark"
YSITE="${HADOOP_CONF_DIR}/yarn-site.xml"

# ---------------------------------------------------------------- plan / dry
est=0; plan=()
for g in ${SIZES}; do
  [ "${g}" = 1 ] && plan+=("A  1 GB  use existing input, ${RUNS} runs, pool ${POOL_BASE}, R${R_BEST}") \
                 || plan+=("A  ${g} GB  HSGen + ${RUNS} runs, pool ${POOL_BASE}, R${R_BEST}")
  est=$((est + RUNS * 95 * g + (g > 1 ? 45 * g : 0)))
  if [ "${g}" = "${RES_SIZE}" ] && [ "${RES}" = 1 ]; then
    for p in 1920 7680; do
      plan+=("B  ${RES_SIZE} GB  pool ${p} MB (${RES_VCORES[$p]} vcores), R${RES_REDUCERS[$p]}, ${RUNS} runs")
    done
    est=$((est + RUNS * (360 + 120) + 120))
  fi
done
plan+=("-  regenerate 1 GB baseline, check CHECKSUM ${REF_1G}")
est=$((est + 60))
if [ "${DRY:-0}" = 1 ]; then
  echo "Plan (~$((est / 60)) min if nothing hangs):"; printf '  %s\n' "${plan[@]}"; exit 0
fi

# ---------------------------------------------------------------- checks
[ -f "${JAR}" ] || die "Missing ${JAR}"
for f in 03-start-cluster.sh 04-stop-cluster.sh 05-hsgen.sh 10-phase-breakdown.sh; do
  [ -f "${S}/${f}" ] || die "scripts/${f} is missing"; chmod +x "${S}/${f}"
done
grep -q 'yarn.nodemanager.resource.memory-mb' "${YSITE}" || die "Cannot find memory-mb in ${YSITE}"
NEED_GB=$(( $(echo ${SIZES} | tr ' ' '\n' | sort -n | tail -1) * 4 + 5 ))
AVAIL_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[ "${AVAIL_GB}" -ge "${NEED_GB}" ] || die "Need ~${NEED_GB} GB free, have ${AVAIL_GB} GB"

mkdir -p "${REPO_DIR}/logs"
BLOG="${REPO_DIR}/logs/scale-$(date +%Y%m%d-%H%M%S).log"
ln -sfn "$(basename "${BLOG}")" "${REPO_DIR}/logs/scale-latest.log"
exec > >(tee -a "${BLOG}") 2>&1
SUMMARY="${REPO_DIR}/logs/M3-scale-summary.tsv"
[ -f "${SUMMARY}" ] || printf 'time\texperiment\tsize_gb\tpool_mb\tmaps_real\treducers\trun\thssort_s\thsvalidate_s\tvalidate\tsort_job\n' > "${SUMMARY}"

# ---------------------------------------------------------------- helpers
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
snapshot() { echo "  [$(date +%T)] $1: $(free -h | awk '/^Mem/{print "mem used "$3", avail "$7}; /^Swap/{print "swap "$3}' | paste -sd' ' -) | disk $(df -h / | awk 'NR==2{print $4" free"}')"; }

kill_apps() {
  for a in $(timeout 60 yarn application -list 2>/dev/null | awk '/^application_/{print $1}'); do
    timeout 60 yarn application -kill "${a}" >/dev/null 2>&1 || true
  done
}
yarn_ready() {   # wait until the NodeManager reports the expected pool
  local want="$1" i
  for i in $(seq 1 40); do
    if timeout 30 yarn node -list -showDetails 2>/dev/null | grep -q "memory:${want},"; then return 0; fi
    if timeout 10 curl -s http://localhost:8088/ws/v1/cluster/metrics 2>/dev/null | grep -q "\"totalMB\":${want},"; then return 0; fi
    sleep 3
  done
  return 1
}
cluster_ok() {
  for d in NameNode DataNode ResourceManager NodeManager SecondaryNameNode; do
    "${JAVA_HOME}/bin/jps" | grep -qw "${d}" || return 1
  done
  timeout 60 hdfs dfs -ls / >/dev/null 2>&1
}
restart_cluster() {
  log "Restarting cluster"
  kill_apps
  timeout 180 "${S}/04-stop-cluster.sh" >/dev/null 2>&1 || true
  pkill -f 'org.apache.hadoop' 2>/dev/null || true; sleep 3
  timeout 300 "${S}/03-start-cluster.sh" | tail -3
}

CUR_POOL=""
set_pool() {     # rewrite the NodeManager pool and restart YARN only
  local mb="$1" vc="${RES_VCORES[$1]}"
  [ "${CUR_POOL}" = "${mb}" ] && return 0
  log "YARN pool -> ${mb} MB / ${vc} vcores (restarting YARN)"
  python3 - "${YSITE}" "${mb}" "${vc}" <<'PY'
import re, sys
p, mb, vc = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
for name, val in (("yarn.nodemanager.resource.memory-mb", mb),
                  ("yarn.nodemanager.resource.cpu-vcores", vc)):
    s, n = re.subn(r"(<name>\s*" + re.escape(name) + r"\s*</name>\s*<value>)\s*[^<]*\s*(</value>)",
                   r"\g<1>" + val + r"\g<2>", s)
    if n != 1: sys.exit("could not set " + name)
open(p, "w").write(s)
PY
  [ $? -eq 0 ] || return 1
  kill_apps
  timeout 120 "${HADOOP_HOME}/sbin/stop-yarn.sh" >/dev/null 2>&1 || true
  sleep 3
  timeout 120 "${HADOOP_HOME}/sbin/start-yarn.sh" >/dev/null 2>&1 || true
  if yarn_ready "${mb}"; then CUR_POOL="${mb}"; echo "  pool confirmed: memory:${mb}"; return 0; fi
  echo "  NodeManager did not report memory:${mb}"; return 1
}

cp "${YSITE}" "${YSITE}.scale-backup"
restore_pool() {
  if ! cmp -s "${YSITE}" "${YSITE}.scale-backup"; then
    log "Restoring original yarn-site.xml and restarting YARN"
    cp "${YSITE}.scale-backup" "${YSITE}"
    kill_apps
    timeout 120 "${HADOOP_HOME}/sbin/stop-yarn.sh" >/dev/null 2>&1 || true
    sleep 3
    timeout 120 "${HADOOP_HOME}/sbin/start-yarn.sh" >/dev/null 2>&1 || true
    yarn_ready "${POOL_BASE}" && echo "  pool back to ${POOL_BASE} MB" || echo "  WARNING: check the pool by hand"
  fi
}
trap restore_pool EXIT

REF_DEC=""        # HSGen checksum of the dataset currently in HDFS
gen() {           # gen <GB>: regenerate input, time HSGen, remember its checksum
  local g="$1" glog secs ck
  log "HSGen ${g} GB"
  timeout 120 hdfs dfs -rm -r -skipTrash "${D}/HSsort-input" "${D}/HSsort-output" "${D}/HSvalidate" >/dev/null 2>&1 || true
  if ! timeout $((300 + 120 * g)) "${S}/05-hsgen.sh" "${g}" > /dev/null 2>&1; then
    echo "  HSGen ${g} GB FAILED"; return 1
  fi
  glog="$(ls -t "${REPO_DIR}"/logs/HSGen-${g}GB-*.log 2>/dev/null | head -1)"
  ck="$(grep -oE 'CHECKSUM=[0-9]+' "${glog}" | head -1 | cut -d= -f2)"
  secs="$(awk '/^real/{split($2,a,/[ms]/); printf "%.1f", a[1]*60+a[2]}' "${glog}")"
  [ -n "${ck}" ] || { echo "  no CHECKSUM in ${glog}"; return 1; }
  REF_DEC="${ck}"
  printf '%s\thsgen\t%s\t%s\t-\t-\t1\t%s\t-\t-\t-\n' "$(date +%Y%m%d-%H%M%S)" "${g}" "${CUR_POOL}" "${secs}" >> "${SUMMARY}"
  echo "  HSGen ${g} GB: ${secs} s, CHECKSUM ${ck}"
}

pair() {          # pair <experiment> <GB> <pool> <reducers> <run>
  local ex="$1" g="$2" pool="$3" r="$4" n="$5"
  local stamp LOG lim t0 t1 t2 rc report verdict hex mreal job s v
  stamp="$(date +%Y%m%d-%H%M%S)"
  LOG="${REPO_DIR}/logs/M3-S${g}G-P${pool}-R${r}-run${n}-${stamp}.log"
  lim=$(( 240 + 200 * g * POOL_BASE / pool ))
  timeout 120 hdfs dfs -rm -r -skipTrash "${D}/HSsort-output" "${D}/HSvalidate" >/dev/null 2>&1 || true
  log "${ex}: ${g} GB, pool ${pool}, reducers ${r}, run ${n}/${RUNS}  (limit ${lim} s)"
  { echo "== df before"; df -h / | tail -1; echo "== HSSort"; } >> "${LOG}"
  t0=$(date +%s.%N)
  timeout -k 15 "${lim}" hadoop jar "${JAR}" HSSort \
      -Dmapreduce.job.maps=4 -Dmapreduce.job.reduces="${r}" \
      -Dmapred.map.tasks=4   -Dmapred.reduce.tasks="${r}" \
      "${D}/HSsort-input" "${D}/HSsort-output" >> "${LOG}" 2>&1
  rc=$?; t1=$(date +%s.%N)
  { echo "== df after sort"; df -h / | tail -1; echo "== HSValidate"; } >> "${LOG}"
  if [ "${rc}" -eq 0 ]; then
    timeout -k 15 "${lim}" hadoop jar "${JAR}" HSValidate "${D}/HSsort-output" "${D}/HSvalidate" >> "${LOG}" 2>&1
    rc=$?
  fi
  t2=$(date +%s.%N)
  s=$(elapsed "${t0}" "${t1}"); v=$(elapsed "${t1}" "${t2}")
  if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
    verdict="TIMEOUT"
  elif [ "${rc}" -ne 0 ]; then
    verdict="FAILED(rc=${rc})"
  else
    report="$(timeout 60 hdfs dfs -cat "${D}/HSvalidate/part-*" 2>/dev/null || true)"
    { echo "== HSValidate output"; echo "${report}"; } >> "${LOG}"
    hex="$(echo "${report}" | awk 'tolower($1)=="checksum"{print tolower($2)}' | head -1)"
    if echo "${report}" | grep -qiE 'misorder|bad key|error'; then verdict="FAIL"
    elif [ -n "${REF_DEC}" ] && [ "${hex}" = "$(printf '%x' "${REF_DEC}")" ]; then verdict="PASS(checksum)"
    else verdict="CHECK"; fi
  fi
  mreal="$(grep -m1 -oE 'number of splits:[0-9]+' "${LOG}" | cut -d: -f2)"
  job="$(grep -m1 -oE 'Running job: job_[0-9_]+' "${LOG}" | awk '{print $3}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${stamp}" "${ex}" "${g}" "${pool}" "${mreal:-?}" "${r}" "${n}" \
         "${s}" "${v}" "${verdict}" "${job:-?}" >> "${SUMMARY}"
  echo "  maps ${mreal:-?} | HSSort ${s} s | HSValidate ${v} s | ${verdict}"
  case "${verdict}" in
    TIMEOUT|FAILED*) restart_cluster; yarn_ready "${pool}" || echo "  WARNING: pool ${pool} not confirmed after restart" ;;
    *) cluster_ok || restart_cluster ;;
  esac
  snapshot "after"
}

# ---------------------------------------------------------------- run
log "Scalability batch start (log: logs/$(basename "${BLOG}"))"
printf '  %s\n' "${plan[@]}"
snapshot "start"
cluster_ok || restart_cluster || die "Cluster does not come up"
grep -A1 'yarn.nodemanager.resource.memory-mb' "${YSITE}" | grep -q ">${POOL_BASE}<" \
  || die "yarn-site.xml pool is not ${POOL_BASE} MB at start -- restore it first"
yarn_ready "${POOL_BASE}" || die "NodeManager does not report ${POOL_BASE} MB"
CUR_POOL="${POOL_BASE}"

for g in ${SIZES}; do
  if [ "${g}" = 1 ] && [ -z "${DID_1G:-}" ]; then
    # keep the existing 1 GB input if it is the reference dataset
    bytes="$(timeout 60 hdfs dfs -du -s "${D}/HSsort-input" 2>/dev/null | awk '{print $1}')"
    if [ "${bytes:-0}" = 1000000000 ]; then REF_DEC="${REF_1G}"; echo "  using existing 1 GB input"
    else gen 1 || continue; fi
    DID_1G=1
  else
    gen "${g}" || continue
  fi
  for n in $(seq 1 "${RUNS}"); do pair "data" "${g}" "${POOL_BASE}" "${R_BEST}" "${n}"; done

  if [ "${g}" = "${RES_SIZE}" ] && [ "${RES}" = 1 ]; then
    for p in 1920 7680; do
      if set_pool "${p}"; then
        for n in $(seq 1 "${RUNS}"); do pair "resource" "${g}" "${p}" "${RES_REDUCERS[$p]}" "${n}"; done
      else
        echo "  skipping pool ${p}: could not apply it"
      fi
    done
    restore_pool; CUR_POOL="${POOL_BASE}"
  fi
done

log "Regenerating the 1 GB baseline dataset"
if gen 1 && [ "${REF_DEC}" = "${REF_1G}" ]; then echo "  baseline restored, CHECKSUM matches"
else echo "  WARNING: 1 GB CHECKSUM is ${REF_DEC:-?}, expected ${REF_1G}"; fi

log "Scalability summary (logs/M3-scale-summary.tsv)"
column -t -s $'\t' "${SUMMARY}" | cut -c1-140
log "Per-phase breakdown (scalability runs)"
"${S}/10-phase-breakdown.sh" scale
log "Batch done"
