# System architecture -- TPCx-HS Milestone 2

## Components and their roles

All five daemons run on one physical host (pseudo-distributed mode): each is a
separate JVM talking over the loopback interface, so the code paths are the
same as a real cluster's while the hardware is a single VM.

| Layer   | Daemon              | Heap   | Role in a TPCx-HS run                                          |
|---------|---------------------|--------|----------------------------------------------------------------|
| Storage | **NameNode**        | 512 MB | Holds the filesystem namespace and the block map in memory. Decides which DataNode stores each 128 MB block. Never touches record data. |
| Storage | **DataNode**        | 256 MB | Stores the actual blocks on the local ext4 volume and serves them to tasks. The only daemon that moves bulk data. |
| Storage | **SecondaryNameNode** | 256 MB | Periodically merges the edit log into a new fsimage checkpoint. Not a hot standby -- it exists so the edit log cannot grow without bound. |
| Compute | **ResourceManager** | 384 MB | Cluster-wide scheduler. Owns the pool of 3840 MB / 4 vcores and hands out container leases. |
| Compute | **NodeManager**     | 384 MB | Per-node agent. Launches and monitors containers, enforces their memory limits, and serves map output during the shuffle. |

Each MapReduce job additionally starts a short-lived **ApplicationMaster**
(768 MB container) that asks the ResourceManager for task containers and
retries failures.

## Data flow: HSGen

```
  ./scripts/05-hsgen.sh 1   (kit HSGen, 10,000,000 records)
        |
        | (1) client submits the kit's HSGen job
        v
  ResourceManager  --(2) allocates AM container-->  NodeManager
        |                                                |
        |                                      (3) starts ApplicationMaster
        v                                                v
  AM requests 4 map containers  ------------------>  NodeManager launches them
                                                         |
                                        (4) each mapper generates its slice of
                                            10,000,000 x 100-byte records
                                            (2,500,000 records each)
                                                         |
                                                         v
                                             (5) writes part-m-0000N straight
                                                 to HDFS -- map-only job,
                                                 zero reducers, no shuffle
                                                         |
                   NameNode <--(6) "where do these blocks go?"-- HDFS client in the map task
                                                         |
                                                         v
                                        /user/jiho/TPCx-HS-benchmark/HSsort-input/part-m-0000{0..3}
                                        ~8 blocks x 128 MB, replication 1
```

Two properties matter for the benchmark:

- **HSGen is map-only.** `HSGen.java:300` calls `job.setNumReduceTasks(0)`,
  overriding whatever `-Dmapreduce.job.reduces` is passed, so there is no shuffle and
  no sort. Generation is write-bandwidth-bound, not memory-bound: peak map
  physical memory in the 1 GB run was ~340 MB.
- **Data lands directly in HDFS.** The mappers write through the DataNode, so
  the dataset never passes through the local filesystem as an intermediate
  copy. Disk use is therefore ~1x the dataset, not 2x.

## Data flow: HSSort (Milestone 3, for context)

HSSort is the step this architecture has to be sized for, because it is the
one with a shuffle:

```
  map phase: read 1 GB from HDFS, partition by key range (TotalOrderPartitioner)
        |
        v  spill to yarn.nodemanager.local-dirs  (~1x input on local disk)
  shuffle:  reducers pull their partitions over HTTP from the NodeManager
        |
        v
  reduce phase: merge-sort and write sorted output back to HDFS (~1x input)
```

Peak disk demand is therefore roughly **3x the input** (HDFS input + local
spill + HDFS output), which is the constraint that keeps the dataset at 1-2 GB on
a volume with 9.4 GB free. `scripts/05-hsgen.sh` enforces this before
generating anything.

## Why these memory numbers

Total RAM is 7.7 GiB (measured 2026-11-05) and roughly 1.7 GB is held by the
VS Code server. The budget:

```
  daemon heaps (512+256+256+384+384)            = 1792 MB ceiling
  YARN container pool                           = 3840 MB
  yarn.scheduler.maximum-allocation-mb          = 1024 MB  (one container cap)
```

The pool holds the ApplicationMaster plus 4 map containers at 768 MB each.
`yarn.scheduler.minimum-allocation-mb` is 256 because requests round up to a
multiple of it: at 512, a 768 MB request became 1024 MB and only one map could
run at a time. Daemon ceilings, pool and VS Code server total ~7.3 GB at peak,
so this budget does not fit a 4 GB VM.
`yarn.nodemanager.vmem-check-enabled=false` is required because the
JVM reserves a large virtual address space on aarch64 and the default 2.1x
vmem ratio would kill healthy containers; physical-memory enforcement stays on
via `pmem-check-enabled=true`.
