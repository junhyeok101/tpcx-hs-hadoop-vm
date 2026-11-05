#!/usr/bin/env bash
#
# Preflight check for a FRESH VM. Run this before 01-install.sh.
# Reports everything that is wrong in one pass instead of failing halfway
# through the build. Read-only: changes nothing.
set -uo pipefail
. "$(dirname "$0")/00-env.sh"

fail=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }

echo "=== Architecture and OS ==="
arch="$(uname -m)"
if [ "${arch}" = "aarch64" ]; then
  ok "aarch64 — matches the pinned JDK and Hadoop tarballs"
else
  bad "architecture is ${arch}, but 00-env.sh pins aarch64 binaries.
        Edit HADOOP_TARBALL/HADOOP_URL/JDK_URL in 00-env.sh for ${arch}
        (Hadoop ships hadoop-<ver>.tar.gz for x86_64)."
fi
if [ -r /etc/os-release ]; then
  . /etc/os-release
  ok "${PRETTY_NAME:-unknown}"
else
  warn "cannot read /etc/os-release"
fi

echo
echo "=== Hardware ==="
cores="$(nproc)"
[ "${cores}" -ge 2 ] && ok "${cores} vCPU" \
  || bad "${cores} vCPU — need at least 2; YARN is configured for 4 vcores"
[ "${cores}" -lt 4 ] && warn "fewer than 4 vCPU: lower yarn.nodemanager.resource.cpu-vcores
        and NUM_MAPS in conf/kit/Benchmark_Parameters.sh to match"

mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
if   [ "${mem_mb}" -ge 7000 ]; then ok "${mem_mb} MB RAM"
elif [ "${mem_mb}" -ge 2500 ]; then
  warn "${mem_mb} MB RAM — the committed config assumes ~7.7 GB.
        Lower yarn.nodemanager.resource.memory-mb (currently 3840) and the
        daemon heaps in conf/hadoop/hadoop-env-tpcxhs.sh."
else
  bad "${mem_mb} MB RAM is too little for five daemons plus containers"
fi

swap_mb=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo)
[ "${swap_mb}" -ge 1024 ] && ok "${swap_mb} MB swap" \
  || warn "${swap_mb} MB swap — the memory budget leaves little headroom at
        peak; consider adding some"

avail_gb=$(df -BG --output=avail "${HOME}" | tail -1 | tr -dc '0-9')
if   [ "${avail_gb}" -ge 10 ]; then ok "${avail_gb} GB free on ${HOME}"
elif [ "${avail_gb}" -ge 6  ]; then warn "${avail_gb} GB free — enough for a 1 GB dataset, tight for Milestone 3"
else bad "${avail_gb} GB free — need ~6 GB minimum (1 GB input + 3x for the sort + headroom)"
fi

echo
echo "=== Required commands ==="
for c in wget tar ssh ssh-keygen awk sed df; do
  command -v "$c" >/dev/null && ok "$c" || bad "$c missing — install it (wget: apt install wget)"
done
# Only flag a java that is NOT the one this build installs.
sysjava="$(command -v java 2>/dev/null || true)"
case "${sysjava}" in
  "")                 ok "no system java (the build installs its own)" ;;
  "${OPT_DIR}"/*)     ok "java on PATH is this build's own (${sysjava})" ;;
  *) warn "a system java exists at ${sysjava}
        ($(java -version 2>&1 | head -1)).
        Harmless: every script sets JAVA_HOME=${OPT_DIR}/java8 explicitly." ;;
esac

echo
echo "=== SSH server (Hadoop's sbin scripts ssh into localhost) ==="
if ss -tln 2>/dev/null | grep -q ':22 '; then
  ok "sshd is listening on :22"
else
  bad "no sshd on :22 — start-dfs.sh cannot start any daemon.
        Fix: sudo apt install -y openssh-server && sudo systemctl enable --now ssh"
fi

echo
echo "=== TPCx-HS kit ==="
KIT_HOME="${KIT_HOME:-${KIT_ROOT}/TPCx-HS-Runtime-Suite}"
if [ -f "${KIT_HOME}/TPCx-HS-master_MR2.jar" ]; then
  ok "kit found at ${KIT_HOME} (v$(cat "${KIT_HOME}/VERSION.txt" 2>/dev/null || echo '?'))"
else
  warn "kit not at ${KIT_HOME}.
        Steps 01-04 (install, configure, start) do not need it; only HSGen does.
        Download it from https://www.tpc.org/tpcx-hs/ and unpack it there, or
        export KIT_HOME=/path/to/TPCx-HS-Runtime-Suite. It is not redistributable,
        so it is deliberately absent from this repository."
fi

echo
echo "=== Network: Hadoop mirrors ==="
reachable=0
while read -r url; do
  [ -n "${url}" ] || continue
  host="$(echo "${url}" | cut -d/ -f3)"
  if timeout 12 wget -q --spider --tries=1 --timeout=10 "${url}" 2>/dev/null; then
    ok "${host}"; reachable=$((reachable+1))
  else
    warn "${host} unreachable or too slow to probe"
  fi
done <<< "${HADOOP_MIRRORS}"
if [ "${reachable}" -gt 0 ]; then
  ok "${reachable} mirror(s) reachable — 01-install.sh tries them in order"
else
  bad "no Hadoop mirror reachable. Check the VM's network/DNS, or download
        ${HADOOP_TARBALL} by hand into downloads/ (01-install.sh will
        checksum-verify it and skip the download)."
fi

echo
if [ "${fail}" -eq 0 ]; then
  echo "Preflight passed. Next: ./scripts/01-install.sh"
else
  echo "Preflight FAILED — fix the items marked FAIL above, then re-run."
  exit 1
fi
