#!/usr/bin/env bash
#
# Milestone 3 -- per-phase breakdown of every HSSort run, read back from the
# logs that 08-hssort-validate.sh kept. Nothing is re-run.
#
# For the HSSort part of each log it reports
#   setup   : first Hadoop log line -> "Running job"   (input sampling, partition file, submit)
#   map     : "Running job"         -> first "map 100%" (all 8 maps finished)
#   tail    : "map 100%"            -> "completed successfully" (rest of shuffle + reduce)
# and the job counters that explain them (spills, shuffle volume, GC, reduce time).
#
# Covers all experiments: logs/M3-R<r>-run*.log (08), logs/M3-M<m>-R<r>-run*.log (09)
# and logs/M3-S<g>G-P<pool>-R<r>-run*.log (12, scalability).
# The map count reported is the real one, read from "number of splits".
#
# Usage: ./scripts/10-phase-breakdown.sh            (all M3 run logs)
#        ./scripts/10-phase-breakdown.sh 4 7         (only those reducer counts, experiments 1-2)
#        ./scripts/10-phase-breakdown.sh scale       (only the scalability runs)
set -euo pipefail
. "$(dirname "$0")/00-env.sh"

shopt -s nullglob
files=()
if [ "${1:-}" = scale ]; then
  files=("${REPO_DIR}"/logs/M3-S*G-P*-R*-run*.log)
elif [ "$#" -gt 0 ]; then
  for r in "$@"; do files+=("${REPO_DIR}"/logs/M3-R"${r}"-run*.log "${REPO_DIR}"/logs/M3-M*-R"${r}"-run*.log); done
else
  files=("${REPO_DIR}"/logs/M3-R*-run*.log "${REPO_DIR}"/logs/M3-M*-R*-run*.log "${REPO_DIR}"/logs/M3-S*G-P*-R*-run*.log)
fi
[ "${#files[@]}" -gt 0 ] || die "No M3 run logs found in logs/"

OUT="${REPO_DIR}/logs/M3-phases.tsv"
[ "${1:-}" = scale ] && OUT="${REPO_DIR}/logs/M3-scale-phases.tsv"
{
printf 'experiment\tmaps\treducers\trun\tsetup_s\tmap_s\ttail_s\ttotal_s\tlaunched_reduces\tspilled_records\tshuffle_MB\tgc_s\treduce_task_s\tlog\n'
for f in "${files[@]}"; do
  base="$(basename "${f}")"
  r="$(echo "${base}" | sed -E 's/^M3-(M[0-9]+-|S[0-9]+G-P[0-9]+-)?R([0-9]+)-run([0-9]+)-.*/\2/')"
  n="$(echo "${base}" | sed -E 's/^M3-(M[0-9]+-|S[0-9]+G-P[0-9]+-)?R([0-9]+)-run([0-9]+)-.*/\3/')"
  case "${base}" in
    M3-M*) ex="maps" ;;
    M3-S*) ex="$(echo "${base}" | sed -E 's/^M3-S([0-9]+)G-P([0-9]+)-.*/scale-\1G-P\2/')" ;;
    *)     ex="reducers" ;;
  esac
  # Only the HSSort section of the log.
  awk '/^== HSSort/{on=1;next} /^== df after sort/{on=0} on' "${f}" | awk -v r="${r}" -v n="${n}" -v ex="${ex}" -v base="${base}" '
    function ts(line,   d, t, p) {               # "2026-11-21 17:47:26,738 ..." -> seconds
      if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}/) == 0) return -1
      d = substr(line, 12, 12); split(d, p, /[:,]/)
      return p[1]*3600 + p[2]*60 + p[3] + p[4]/1000
    }
    function cnt(name, line,   v) { v = line; sub(".*" name "=", "", v); return v + 0 }
    { t = ts($0) }
    t >= 0 && first == ""              { first = t }
    /number of splits:/ && ms == ""    { ms = $0; sub(/.*number of splits:/, "", ms); ms += 0 }
    /Running job: job_/ && run == ""   { run = t }
    / map 100% / && m100 == ""         { m100 = t }
    /completed successfully/           { done = t }
    /Launched reduce tasks=/           { lr = cnt("Launched reduce tasks", $0) }
    /Spilled Records=/                 { sp = cnt("Spilled Records", $0) }
    /Reduce shuffle bytes=/            { sb = cnt("Reduce shuffle bytes", $0) }
    /GC time elapsed \(ms\)=/          { gc = cnt("GC time elapsed \\(ms\\)", $0) }
    /Total time spent by all reduce tasks \(ms\)=/ { rt = cnt("Total time spent by all reduce tasks \\(ms\\)", $0) }
    END {
      if (run == "" || m100 == "" || done == "") { printf "%s\t%s\t%s\t%s\t?\t?\t?\t?\t?\t?\t?\t?\t?\t%s (incomplete)\n", ex, (ms==""?"?":ms), r, n, base; exit }
      printf "%s\t%s\t%s\t%s\t%.1f\t%.1f\t%.1f\t%.1f\t%d\t%d\t%.0f\t%.1f\t%.1f\t%s\n", ex, ms, r, n,
             run-first, m100-run, done-m100, done-first, lr, sp, sb/1048576, gc/1000, rt/1000, base
    }'
done | sort -t $'\t' -k1,1r -k2,2n -k3,3n -k4,4n
} > "${OUT}"

column -t -s $'\t' "${OUT}" | cut -c1-150
echo
echo "saved: ${OUT#${REPO_DIR}/}"
