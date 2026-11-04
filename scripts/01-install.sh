#!/usr/bin/env bash
# Install JDK 8 + Hadoop 3.3.6 (aarch64) under $HOME and apply the TPCx-HS
# pseudo-distributed configuration. No root privileges required.
set -euo pipefail
. "$(dirname "$0")/00-env.sh"

DL_DIR="${REPO_DIR}/downloads"
mkdir -p "${DL_DIR}" "${OPT_DIR}"

log "1/5 Verifying host is aarch64"
[ "$(uname -m)" = "aarch64" ] || die "This script pins aarch64 binaries; host is $(uname -m)."

log "2/5 Fetching tarballs (resumable, mirror fallback)"

# --read-timeout + --tries=0 matter: dlcdn.apache.org stalled mid-transfer during
# this build and a plain wget hung indefinitely instead of retrying.
WGET_OPTS=(-c -q --show-progress --read-timeout=20 --timeout=25 --tries=3 --waitretry=3)

wget "${WGET_OPTS[@]}" -O "${DL_DIR}/${JDK_TARBALL}" "${JDK_URL}" \
  || die "JDK download failed from ${JDK_URL}"

HADOOP_FILE="${DL_DIR}/${HADOOP_TARBALL}"
if [ -f "${HADOOP_FILE}" ] && [ -n "${HADOOP_SHA512:-}" ] \
   && echo "${HADOOP_SHA512}  ${HADOOP_FILE}" | sha512sum -c --status 2>/dev/null; then
  echo "Hadoop tarball already present and checksum-verified; skipping download"
else
  got=0
  while read -r url; do
    [ -n "${url}" ] || continue
    echo "  trying $(echo "${url}" | cut -d/ -f3)"
    if wget "${WGET_OPTS[@]}" -O "${HADOOP_FILE}" "${url}"; then got=1; break; fi
    echo "  -> failed or stalled, next mirror"
  done <<< "${HADOOP_MIRRORS}"
  [ "${got}" -eq 1 ] || die "All mirrors failed. Mirrors tried:
${HADOOP_MIRRORS}"
fi

if [ -n "${HADOOP_SHA512:-}" ]; then
  echo "${HADOOP_SHA512}  ${HADOOP_FILE}" | sha512sum -c - \
    || die "SHA512 mismatch on ${HADOOP_FILE}. Delete it and re-run."
else
  warn_no_checksum=1
fi

log "3/5 Unpacking JDK 8"
if [ ! -d "${OPT_DIR}/java8" ] || [ ! -x "${OPT_DIR}/java8/bin/java" ]; then
  tar xzf "${DL_DIR}/${JDK_TARBALL}" -C "${OPT_DIR}"
  JDK_DIR="$(find "${OPT_DIR}" -maxdepth 1 -name 'jdk8u*' -type d | head -1)"
  [ -n "${JDK_DIR}" ] || die "JDK directory not found after extraction."
  ln -sfn "${JDK_DIR}" "${OPT_DIR}/java8"
fi
"${OPT_DIR}/java8/bin/java" -version

log "4/5 Unpacking Hadoop ${HADOOP_VERSION}"
if [ ! -x "${HADOOP_HOME}/bin/hadoop" ]; then
  tar xzf "${DL_DIR}/${HADOOP_TARBALL}" -C "${OPT_DIR}"
  ln -sfn "${OPT_DIR}/hadoop-${HADOOP_VERSION}" "${HADOOP_HOME}"
fi

log "5/5 Applying configuration from ${REPO_DIR}/conf/hadoop"
SRC="${REPO_DIR}/conf/hadoop"
for f in core-site.xml hdfs-site.xml yarn-site.xml mapred-site.xml workers; do
  cp -v "${SRC}/${f}" "${HADOOP_CONF_DIR}/${f}"
done
# Replace our env block if present, append it if not. Replacing rather than
# skipping matters: if the paths in conf/ change, a stale block would keep
# pointing the daemons at the old locations.
ENVF="${HADOOP_CONF_DIR}/hadoop-env.sh"
if grep -q 'TPCx-HS Milestone 2' "${ENVF}"; then
  python3 - "${ENVF}" <<'STRIP'
import sys
p = sys.argv[1]
s = open(p).read()
i = s.find('# TPCx-HS Milestone 2')
if i != -1:
    j = s.rfind('\n# ---', 0, i)          # start of the banner comment
    open(p, 'w').write(s[:j if j != -1 else i].rstrip() + '\n')
STRIP
  echo "refreshed the TPCx-HS block in hadoop-env.sh"
else
  echo "appending the TPCx-HS block to hadoop-env.sh"
fi
cat "${SRC}/hadoop-env-tpcxhs.sh" >> "${ENVF}"

mkdir -p "${DATA_DIR}"/{nn,dn,tmp,logs,pids,yarn/local,yarn/logs}

log "Install complete"
"${HADOOP_HOME}/bin/hadoop" version
