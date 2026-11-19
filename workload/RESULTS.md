# Results

## Status

| Phase | Measured | Where |
|-------|----------|-------|
| HSGen, 1 GB, 4 maps | **Yes** | below |
| HSSort | **Not yet** | to fill |
| HSValidate | **Not yet** | to fill |

Trial HSSort and HSValidate runs exist in the ResourceManager log from
2026-11-04. They ran before the YARN fix of 2026-11-05 (pool 2560 → 3840 MB,
minimum allocation 512 → 256 MB), their output is gone, and they must not be
quoted.

Every cell marked `TBD` below is waiting for a real measurement. Do not fill
one from memory or from another run.

## Measured: HSGen (Milestone 2)

Configuration at the time: YARN pool 2560 MB, one map at a time (the cause was
found and fixed afterwards).

| Metric | Value |
|--------|-------|
| Records | 10,000,000 |
| HDFS bytes written | 1,000,000,000 |
| Map tasks | 4 |
| Wall clock | 28.356 s |
| CHECKSUM | 21472776955442690 |

HSGen has not been re-run since the fix, so its time on the current
configuration is `TBD`.

## Measurement protocol

1. Start clean: `./scripts/03-start-cluster.sh`, confirm five daemons with
   `jps`, and `df -h /` has at least 3× the input free.
2. Stop other load (the VS Code server alone holds ~1.7 GB).
3. For each configuration, run HSSort then HSValidate, timing with `date +%s`
   around each `hadoop jar`, and record the job's own counters.
4. Delete `HSsort-output` and `HSvalidate` between runs.
5. Run each configuration **3 times**; report all three and the median.
6. Record `df -h /` and peak container memory (ResourceManager UI, `:8088`).

```bash
D=/user/$(id -un)/TPCx-HS-benchmark
for run in 1 2 3; do
  hdfs dfs -rm -r -skipTrash $D/HSsort-output $D/HSvalidate 2>/dev/null
  t0=$(date +%s)
  hadoop jar $KIT_HOME/TPCx-HS-master_MR2.jar HSSort \
      -Dmapreduce.job.maps=4 -Dmapreduce.job.reduces=$R $D/HSsort-input $D/HSsort-output
  t1=$(date +%s)
  hadoop jar $KIT_HOME/TPCx-HS-master_MR2.jar HSValidate $D/HSsort-output $D/HSvalidate
  t2=$(date +%s)
  echo "run=$run R=$R sort=$((t1-t0))s validate=$((t2-t1))s"
  hdfs dfs -ls $D/HSvalidate     # must be empty
done
```

## Table to fill: HSSort and HSValidate, 1 GB

| Reducers | Run | HSSort (s) | HSValidate (s) | Validate result | Notes |
|----------|-----|-----------|----------------|-----------------|-------|
| 4 | 1 | TBD | TBD | TBD | |
| 4 | 2 | TBD | TBD | TBD | |
| 4 | 3 | TBD | TBD | TBD | |
| 2 | 1–3 | TBD | TBD | TBD | |
| 3 | 1–3 | TBD | TBD | TBD | at most 3 reducers fit beside the AM |

Once measured, add a bar chart of median HSSort time per reducer count and a
per-phase breakdown (map, shuffle, reduce) from the job counters.

## Reading the numbers

- These times are pessimistic and not comparable to published TPCx-HS results:
  one node, replication 1, 1 GB, and memory shared with the editor server.
- What *is* comparable between our own rows is the effect of a single setting
  changed at a time.
- A validation run that leaves the output directory non-empty is a failed run,
  whatever its time.
