# ---------------------------------------------------------------------------
# TPCx-HS Milestone 2 -- appended to $HADOOP_HOME/etc/hadoop/hadoop-env.sh
# Daemon heaps are sized for a 3.8 GB VM. Five JVMs run concurrently
# (NameNode, DataNode, SecondaryNameNode, ResourceManager, NodeManager);
# the Hadoop defaults of 1 GB each would exceed physical memory.
# ---------------------------------------------------------------------------
export JAVA_HOME=${HOME}/project/opt/java8
export HADOOP_HOME=${HOME}/project/opt/hadoop
export HADOOP_CONF_DIR=${HADOOP_HOME}/etc/hadoop
export HADOOP_LOG_DIR=${HOME}/project/hadoop-data/logs
export HADOOP_PID_DIR=${HOME}/project/hadoop-data/pids

# Ceiling for any Hadoop JVM that does not set its own -Xmx (in MB).
export HADOOP_HEAPSIZE_MAX=512

export HDFS_NAMENODE_OPTS="-Xmx512m -XX:+UseParallelGC"
export HDFS_DATANODE_OPTS="-Xmx256m"
export HDFS_SECONDARYNAMENODE_OPTS="-Xmx256m"
export YARN_RESOURCEMANAGER_OPTS="-Xmx384m"
export YARN_NODEMANAGER_OPTS="-Xmx384m"

# Silence the "Unable to load native-hadoop library" warning: the aarch64
# tarball ships real ARM64 .so files, they just need to be on the path.
export HADOOP_OPTS="${HADOOP_OPTS:-} -Djava.library.path=${HADOOP_HOME}/lib/native"
export LD_LIBRARY_PATH="${HADOOP_HOME}/lib/native:${LD_LIBRARY_PATH:-}"
