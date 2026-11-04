# Kit configuration

`Benchmark_Parameters.sh` is a parameter **overlay** written for this repo: it
sets only the shell variables the kit's HSGen/HSSort command lines read, with
values matched to this VM. `scripts/05-hsgen.sh` and
`scripts/07-hsdatacheck.sh` source it.

## What is deliberately not here

The kit's own files — `Benchmark_Parameters.sh` as shipped, `USER_GUIDE.txt`,
the jars, the sources, the specification — are **not committed**. The TPCx-HS
kit EULA v2.1 clause 4.a forbids reproducing or distributing kit material, and
clause 4.a.(3) specifically forbids contributing it to third-party projects.
`.gitignore` blocks them.

Obtain the kit from <https://www.tpc.org/tpcx-hs/> and unpack it to
`~/project/TPCx-HS_Kit_v2.0.3` (or set `KIT_HOME`).

## Values set here

| Variable | Value | Kit default |
|----------|-------|-------------|
| `HADOOP_USER` | `jiho` | `root` |
| `HDFS_USER` | `jiho` | `root` |
| `HDFS_BENCHMARK_DIR` | `TPCx-HS-benchmark` | unchanged |
| `NUM_MAPS` | `4` | `768` |
| `NUM_REDUCERS` | `4` | `768` |
| `SLEEP_BETWEEN_RUNS` | `10` | `60` |

Rationale for each is in the header comment of the file itself, and the wider
analysis of the kit is in [`../../docs/KIT-INTEGRATION.md`](../../docs/KIT-INTEGRATION.md).
