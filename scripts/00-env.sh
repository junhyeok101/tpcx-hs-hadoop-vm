#!/usr/bin/env bash
# Common environment for every script in this directory. Source, do not execute.
set -o pipefail

# Everything this project owns lives under one root so it can be moved or
# deleted as a unit. Override TPCXHS_ROOT to relocate -- but if you do, also
# update the ${user.home}/project/... paths in conf/hadoop/*.xml, because
# Hadoop XML can only expand Java system properties, not shell variables.
export TPCXHS_ROOT="${TPCXHS_ROOT:-${HOME}/project}"

export REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OPT_DIR="${TPCXHS_ROOT}/opt"
export DATA_DIR="${TPCXHS_ROOT}/hadoop-data"
export KIT_ROOT="${TPCXHS_ROOT}/TPCx-HS_Kit_v2.0.3"

export JAVA_HOME="${OPT_DIR}/java8"
export HADOOP_HOME="${OPT_DIR}/hadoop"
export HADOOP_CONF_DIR="${HADOOP_HOME}/etc/hadoop"
export HADOOP_MAPRED_HOME="${HADOOP_HOME}"
export HADOOP_COMMON_HOME="${HADOOP_HOME}"
export HADOOP_HDFS_HOME="${HADOOP_HOME}"
export YARN_HOME="${HADOOP_HOME}"
export HADOOP_COMMON_LIB_NATIVE_DIR="${HADOOP_HOME}/lib/native"
export LD_LIBRARY_PATH="${HADOOP_HOME}/lib/native:${LD_LIBRARY_PATH:-}"
export PATH="${JAVA_HOME}/bin:${HADOOP_HOME}/bin:${HADOOP_HOME}/sbin:${PATH}"

# Versions pinned for Milestone 2 (aarch64 / Ubuntu 22.04)
export HADOOP_VERSION="3.3.6"
export HADOOP_TARBALL="hadoop-${HADOOP_VERSION}-aarch64.tar.gz"
# Mirrors are tried in order. dlcdn.apache.org is the canonical source but was
# measured at ~180 KB/s and stalling outright during this build; mirror.kakao.com
# served the same file at ~1.8 MB/s. All three honour HTTP range requests, so a
# partial download resumes across a mirror switch.
export HADOOP_MIRRORS="\
https://dlcdn.apache.org/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_TARBALL}
https://mirror.kakao.com/apache/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_TARBALL}
https://ftp.kaist.ac.kr/apache/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_TARBALL}
https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_TARBALL}"
export HADOOP_URL="$(echo "${HADOOP_MIRRORS}" | head -1)"
# Published SHA512 for hadoop-3.3.6-aarch64.tar.gz. Verified during the build;
# the upstream .sha512 file labels itself "-RC1" but the digest is this artifact's.
export HADOOP_SHA512="b0a485c5ae0d97b08285bb83a3dd78b834153b2bd53f96ac301852862ccaff139f2c547aee808d5ad4afdc3a204b1c3b6ba459ea83ebf2779e9c129f37c69059"
export JDK_TARBALL="temurin8-aarch64.tar.gz"
export JDK_URL="https://api.adoptium.net/v3/binary/latest/8/ga/linux/aarch64/jdk/hotspot/normal/eclipse"

log()  { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
