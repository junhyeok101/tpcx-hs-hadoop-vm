#!/usr/bin/env bash
#
# Parameter overlay for the TPCx-HS v2.0.3 kit on this single-node VM.
#
# This is OUR file, not a copy of the kit's. It defines only the shell
# variables the kit's HSGen/HSSort command lines read, with the values this
# environment needs. The kit's own Benchmark_Parameters.sh (and its TPC legal
# notice) is NOT reproduced here: the kit EULA v2.1 clause 4.a forbids
# redistributing kit material or contributing it to third-party projects.
# Get the kit from tpc.org.
#
# The kit directory itself is left completely unmodified; scripts/05-hsgen.sh
# and scripts/07-hsdatacheck.sh source THIS file instead.
#
# Values, and why they differ from the kit's shipped defaults:
#
#   HADOOP_USER / HDFS_USER
#       kit ships "root". There is no usable root on this VM (sudo requires a
#       password), and the HDFS superuser is the account that formatted the
#       NameNode, i.e. jiho.
#
#   NUM_MAPS
#       kit ships 768. YARN here offers 4 vcores and a 3840 MB container pool,
#       so 768 map tasks would serialise into ~192 waves and each container
#       would fall below the 256 MB scheduler minimum. 4 matches the vcores.
#
#   NUM_REDUCERS
#       kit ships 768, same reasoning. HSGen ignores it entirely -- its
#       source calls job.setNumReduceTasks(0), making it map-only -- but
#       HSSort in Milestone 3 does use it, and will need retuning there.
#
#   HDFS_BENCHMARK_DIR
#       unchanged from the kit, so HDFS paths match the specification's layout.
#
#   SLEEP_BETWEEN_RUNS
#       kit ships 60. Only used by the kit's multi-run driver loop, which is
#       not run here; shortened so a future scripted loop is less tedious.

#-----------------------------------
# Common
#-----------------------------------
HADOOP_USER="$(id -un)"
HDFS_USER="$(id -un)"
HDFS_BENCHMARK_DIR="TPCx-HS-benchmark"
SLEEP_BETWEEN_RUNS=10

#-----------------------------------
# MapReduce
#-----------------------------------
NUM_MAPS=4
NUM_REDUCERS=4

#-----------------------------------
# Spark -- unused, Spark is not installed on this VM
#-----------------------------------
SPARK_MASTER_URL="yarn"
SPARK_DEPLOY_MODE="cluster"
