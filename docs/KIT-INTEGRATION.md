# TPCx-HS v2.0.3 kit — what is in it, and how it is driven here

## Location

```
~/project/TPCx-HS_Kit_v2.0.3/
├── EULA.txt
├── TPCx-HS Specification.docx          <- the v2.0.3 spec itself
├── TPCx-HS-Runtime-Suite/
│   ├── TPCx-HS-master.sh               <- the driver
│   ├── Benchmark_Parameters.sh         <- settings (adapted copy in conf/kit/)
│   ├── BigData_cluster_validate_suite.sh
│   ├── HSDataCheck.sh                  <- body is literally: hdfs dfs -ls $1/*
│   ├── TPCx-HS-master_MR2.jar          <- used here (Hadoop 2+/3 API)
│   ├── TPCx-HS-master_MR1.jar          <- old MR1 API, unused
│   ├── TPCx-HS-master_Spark.jar        <- Spark, unused (Spark not installed)
│   ├── USER_GUIDE.txt
│   └── VERSION.txt                     <- 2.0.3
└── TPCx-HS-SRC/                        <- Java sources for all of the above
```

The kit directory is **unmodified**. Our parameter overlay lives in this repo
at `conf/kit/Benchmark_Parameters.sh`.

No kit file is committed to this repository: EULA v2.1 clause 4.a forbids
reproducing or distributing kit material, and 4.a.(3) forbids contributing it
to third-party projects. The line/file references below point into the kit on
disk so the findings stay checkable without copying anything.

## Jar compatibility

| Property | Value | Consequence |
|----------|-------|-------------|
| Manifest `Created-By` | `1.7.0_09-icedtea` | built with JDK 7 |
| `HSGen.class` major version | 51 | Java 7 bytecode |
| Runtime used here | JDK 8 (1.8.0_504) | runs unchanged |

Classes in `TPCx-HS-master_MR2.jar`: `HSGen`, `HSSort`, `HSValidate`,
`HSDataCheck`, `GenSort`, `HSInputFormat`, `HSOutputFormat`, `HSScheduler`,
`Random16`, `Unsigned16`. The jar has no `Main-Class`, so the class name is
passed as the first argument to `hadoop jar`.

## Scale factors the driver offers

`hssize` in `TPCx-HS-master.sh` is a **record count**, and a record is 100 B
(`HSInputFormat.java:55-57`: `KEY_LENGTH 10` + `VALUE_LENGTH 90`).

| `-g` | `hssize` (records) | Dataset | Fits this VM? |
|------|--------------------|---------|---------------|
| 1 | 1,000,000,000 | 100 GB ("test purpose only, not a valid Scale Factor") | no |
| 2 | 10,000,000,000 | 1 TB (smallest *valid* scale factor) | no |
| 3–10 | up to 10^14 | 3 TB … 10,000 TB | no |

**There is no `-g` option small enough for a 10 GB HDFS.** This is the central
reason the driver is bypassed.

## Why `TPCx-HS-master.sh` is not run

| # | Finding | Line |
|---|---------|------|
| 1 | Smallest scale factor is 100 GB | `:103` |
| 2 | Runs the full HSGen→HSSort→HSValidate suite **twice** (`for i in seq 1 2`) — Milestone 3 scope | `:~200` |
| 3 | Opens every run with `hadoop fs -rm -r -skipTrash /user/$HADOOP_USER/$HDFS_BENCHMARK_DIR/*` — destroys data with no prompt | `:~218` |
| 4 | Wraps HDFS setup in `sudo -u $HDFS_USER`; `sudo` needs a password on this VM | `:~210` |
| 5 | Cluster Validation Suite needs `clush`/`pdsh` — absent, and pointless on one node | `:45-52` |

## What is run instead

`scripts/05-hsgen.sh` reproduces the driver's HSGen line verbatim
(`TPCx-HS-master.sh:232`), sourcing the adapted parameters:

```bash
hadoop jar TPCx-HS-master_MR2.jar HSGen \
    -Dmapreduce.job.maps=$NUM_MAPS -Dmapreduce.job.reduces=$NUM_REDUCERS \
    -Dmapred.map.tasks=$NUM_MAPS   -Dmapred.reduce.tasks=$NUM_REDUCERS   \
    $hssize /user/$HADOOP_USER/$HDFS_BENCHMARK_DIR/HSsort-input
```

Same class, same flags, same output path — only `hssize` is smaller
(10,000,000 records = 1 GB). `HSGen` is map-only regardless of
`NUM_REDUCERS`: `HSGen.java:300` calls `job.setNumReduceTasks(0)`.

`scripts/07-hsdatacheck.sh` runs both of the kit's check paths.

## One kit bug worth knowing

`TPCx-HS-SRC-MR2/HSDataCheck.java:34`:

```java
conf.set("fs.defaultFS", "hdfs://127.0.0.1:8020" + args[0]);
```

The NameNode address is **hardcoded**, and the path argument is concatenated
onto the URI. Any cluster whose NameNode is not on `127.0.0.1:8020` gets a
`java.net.ConnectException: Connection refused` from this class.

This was hit directly: with `fs.defaultFS=hdfs://localhost:9000` the class
failed while `HSDataCheck.sh` succeeded. Fixed by moving the NameNode to port
**8020** — which is Hadoop's own default anyway — rather than editing kit
source, since a modified kit would be worse for traceability.

## Known issues flagged by the kit itself

`USER_GUIDE.txt` records that **HSValidate** can throw
`java.lang.IndexOutOfBoundsException` due to MAPREDUCE-6635, and that specific
`NUM_MAPS`/`NUM_REDUCERS` combinations (240/200, 768/720, 640/600, 768/768)
are known to work around it. Relevant to Milestone 3, not to HSGen. Those
combinations assume a real cluster; on 4 vcores they will need rethinking.
