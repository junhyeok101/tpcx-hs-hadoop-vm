# TPCx-HS on a Single-Node Hadoop VM

Running the **TPCx-HS v2.0.3** big-data benchmark (HSGen → HSSort → HSValidate,
MapReduce) on a single ARM64 virtual machine, at a scale far below the
specification's minimum, to study how the benchmark's three phases behave on a
memory- and disk-constrained system.

Yonsei University, Big Data course project, 2026-2. Milestones 2 and 3.

> **This is not a TPCx-HS result.** The run uses 1 GB of data on one node with
> replication 1; the specification requires ≥ 1 TB and replication ≥ 3. No
> HSph@SF metric is computed or claimed. See [Deviations](#deviations-from-the-specification).

---

## Project description

[TPCx-HS](https://www.tpc.org/tpcx-hs/) measures Hadoop cluster throughput by
sorting a large dataset of 100-byte records. We built the whole stack by hand on
one VM, generated and verified a dataset, and (Milestone 3) measure how the sort
and the validation pass behave as the configuration is changed.

| Milestone | Scope | Status |
|-----------|-------|--------|
| 2 | Architecture design, Hadoop build, HSGen 1 GB, verification | **Done** |
| 3 | HSSort / HSValidate measurement, results, this GitHub page | **In progress** — measurements not yet recorded, see [results](workload/RESULTS.md) |

## System description

One host, pseudo-distributed Hadoop: five daemons in five JVMs over loopback.

| | |
|---|---|
| Platform | UTM VM on macOS, Ubuntu 22.04 aarch64 |
| Resources | 6 vCPU, 7.7 GiB RAM, 3.8 GiB swap, 30 GB disk |
| Software | Hadoop 3.3.6 (aarch64 native libs), Temurin JDK 8, TPCx-HS kit v2.0.3 (MR2 jar) |
| Daemons | NameNode, DataNode, SecondaryNameNode, ResourceManager, NodeManager |
| YARN pool | 3840 MB / 4 vcores: ApplicationMaster + 4 maps at 768 MB |
| HDFS | replication 1, 128 MB blocks, `hdfs://localhost:8020` |

### Technical details

Key settings ([`conf/hadoop/`](conf/hadoop/)):

| Setting | Value | Reason |
|---------|-------|--------|
| `fs.defaultFS` | `hdfs://localhost:8020` | the kit's `HSDataCheck` hardcodes this address |
| `yarn.nodemanager.resource.memory-mb` | 3840 | AM + 4 maps at 768 MB |
| `yarn.scheduler.minimum-allocation-mb` | 256 | at 512 a 768 MB request rounded to 1024 MB and only one map ran at a time |
| `yarn.nodemanager.vmem-check-enabled` | false | aarch64 JVMs reserve large virtual memory; physical limits stay enforced |
| Daemon heaps | 512/256/256/384/384 MB | five default 1 GB heaps would not fit in RAM |

Everything is installed under `~/project` without root.

## Workload

TPCx-HS is not a query benchmark. Its "queries" are three MapReduce programs
that run in sequence over one dataset of 100-byte records (10-byte key, 90-byte
value):

| Phase | Program | What it does | Shape |
|-------|---------|--------------|-------|
| 1 | **HSGen** | Generates records deterministically from the record number | map-only, write-bound |
| 2 | **HSSort** | Total-order sorts the whole dataset | map → shuffle → reduce, ~3× input in disk |
| 3 | **HSValidate** | Checks global key order and that no record was lost or changed | ordering + CRC32 sum |

Dataset: **1 GB = 10,000,000 records**, 4 files of 250 MB. HSGen CHECKSUM
`21472776955442690`, which HSValidate must reproduce after sorting.

Full description with diagrams, record layout and the validation logic:
[workload/README.md](workload/README.md).

## Results

Milestone 2 (measured): HSGen of 1 GB took **28.4 s** with 4 maps. The dataset
was verified byte-for-byte against an independent regeneration.

Milestone 3 HSSort / HSValidate timings: [workload/RESULTS.md](workload/RESULTS.md).
That page lists the measurement protocol and the table to fill; **no
HSSort/HSValidate number is reported anywhere in this repository until it has
been measured on the post-fix configuration.** Earlier trial runs predate the
YARN fix of 2026-11-05 and are deliberately discarded.

## Execution commands

The TPCx-HS kit is **not** included (its EULA forbids redistribution). Download
it from <https://www.tpc.org/tpcx-hs/> and unpack it to
`~/project/TPCx-HS_Kit_v2.0.3`, or `export KIT_HOME=/path/to/TPCx-HS-Runtime-Suite`.

```bash
mkdir -p ~/project && cd ~/project
git clone <this repo> tpcxhs-m2 && cd tpcxhs-m2

./scripts/00-preflight.sh      # checks arch, RAM, disk, sshd, kit, mirrors
./scripts/01-install.sh        # JDK 8 + Hadoop 3.3.6 under ~/project/opt, apply conf/
./scripts/01b-setup-ssh.sh     # passwordless ssh to localhost
./scripts/02-format-hdfs.sh    # format NameNode
./scripts/03-start-cluster.sh  # start HDFS + YARN
./scripts/05-hsgen.sh 1        # HSGen, 1 GB
./scripts/07-hsdatacheck.sh    # kit's HSDataCheck + size accounting
```

Milestone 3 phases (command lines taken from the kit's own driver):

```bash
D=/user/$(id -un)/TPCx-HS-benchmark
hadoop jar $KIT_HOME/TPCx-HS-master_MR2.jar HSSort \
    -Dmapreduce.job.maps=4 -Dmapreduce.job.reduces=4 $D/HSsort-input $D/HSsort-output
hadoop jar $KIT_HOME/TPCx-HS-master_MR2.jar HSValidate $D/HSsort-output $D/HSvalidate
hdfs dfs -ls $D/HSvalidate     # empty output directory = PASS
```

Everything is derived from `$HOME` and the current username, so no path edits
are needed on another machine. Expect ~5–15 min for `01-install.sh` (711 MB
download; it tries several mirrors because the default one stalls), seconds for
the rest, ~30 s for HSGen. `openssh-server` must be installed or no daemon
starts; `00-preflight.sh` checks for it.

**Full setup guide for a fresh VM** (VM sizing, kit location, build pitfalls, SSH, and how to run
Milestone 3): [SETUP.md](SETUP.md).

## Deviations from the specification

| Specification | This project | Why |
|---------------|--------------|-----|
| Scale factor ≥ 1 TB | 1 GB | ~10 GB of usable HDFS |
| Replication ≥ 3 | 1 | one node |
| Cluster of nodes | one VM | course constraint |
| `TPCx-HS-master.sh` driver | HSGen/HSSort/HSValidate invoked directly | the driver's smallest scale is 100 GB, it deletes data unprompted and needs `sudo` |
| Cluster Validation Suite | skipped | needs `clush`/`pdsh`; meaningless on one node |

Also: daemons and heaps share ~7.7 GiB with the editor server, so timings are
pessimistic, and software is installed under `$HOME` because `sudo` needs a password.

## Repository layout

```
.
├── README.md             this page
├── conf/
│   ├── hadoop/           core/hdfs/yarn/mapred-site, hadoop-env, workers
│   └── kit/              our TPCx-HS parameter overlay (no kit files)
├── SETUP.md              build the cluster on a fresh VM, run Milestone 3
├── scripts/              numbered build/run scripts, 00 … 07, plus 99 (optional)
└── workload/
    ├── README.md         the benchmark workload and dataset
    └── RESULTS.md        measurement protocol and results
```

## Licence note

No TPCx-HS kit material is committed here (kit EULA v2.1, clause 4.a). The
scripts and configuration in this repository are our own work.
