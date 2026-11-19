# Workload: TPCx-HS

## Workload description

TPCx-HS (TPC Express Benchmark HS) measures the throughput of a Hadoop cluster
by running a Terasort-style job. It has no SQL queries. The workload is three
programs, run one after another over a single dataset.

## Workload diagram

```
   HSGen  ───────►  HSSort  ───────►  HSValidate
   write            read, shuffle,     read
   1 GB             write 1 GB         check order + checksum
   (map-only)       (map+reduce)       (map + 1 reduce)
```

The official metric, HSph@SF, is derived from the elapsed time of the sort and
validation phases and the scale factor. It is not computed here (see the
[deviations](../README.md#deviations-from-the-specification)); we report phase
times directly.

## Dataset

| | |
|---|---|
| Record size | 100 bytes: 10-byte key + 90-byte value (`HSInputFormat.java:55-57` in the kit) |
| Scale | 1 GB = **10,000,000 records** (`records = GB × 10,000,000`) |
| Layout in HDFS | 4 files `part-m-00000…3`, 250,000,000 B each, replication 1 |
| Path | `/user/<user>/TPCx-HS-benchmark/HSsort-input` |
| Generator | the kit's `HSGen`, 4 map tasks of 2,500,000 records |
| Determinism | each record is a pure function of its record number (`Random16.skipAhead(rowId)`) |
| Reference value | `HSGen$Counters CHECKSUM = 21472776955442690` |

### Record layout

Produced by the kit's `GenSort.generateRecord`:

```
 0         10  12                       44      48           96    100
 ├──────────┼───┼────────────────────────┼───────┼────────────┼──────┤
 │   key    │ 0x00 0x11 │ 32 B ASCII-hex   │ 88 99 AA BB │ 48 B filler │ CC DD EE FF │
 │  10 B    │           │ record number    │             │             │             │
```

The key is the high 10 bytes of a 128-bit pseudo-random value, so keys are
uniformly distributed and the sort has no skew to exploit.

The dataset was verified independently of Hadoop: the kit's `GenSort` was
compiled standalone and regenerated the first records byte-for-byte, and
re-summing all 10,000,000 records reproduces the CHECKSUM above.

## Queries / Operations

All three programs are used, so there is no subset to choose (other teams picked
subsets of TPC-H queries; TPCx-HS has none). Each program is one operation:

### 1. HSGen — data generation

- **Map-only.** `HSGen.java:300` calls `setNumReduceTasks(0)`, so there is no
  shuffle and no sort.
- Each of the 4 mappers writes its 250 MB slice directly to HDFS.
- Write-bandwidth-bound. Measured: **28.4 s** wall clock for 1 GB; peak map
  memory about 340 MB.

### 2. HSSort — the measured phase

```
  map:     read input from HDFS, partition by key range (TotalOrderPartitioner)
             │
             ▼  spill to local disk  (~1× input)
  shuffle: each reducer pulls its key range from the NodeManager over HTTP
             │
             ▼
  reduce:  merge-sort, write sorted output to HDFS  (~1× input)
```

- Peak disk need is about **3× the input** (HDFS input + spill + HDFS output).
  That, not RAM, is why the dataset stays at 1 GB on a volume with ~9 GB free.
- On this VM the ApplicationMaster (768 MB) and the reducers (1024 MB) share a
  3840 MB pool, so at most three reducers run beside the AM.
- Input `…/HSsort-input`, output `…/HSsort-output`.

### 3. HSValidate — correctness

Two independent properties are checked; both are needed.

| Property | How | Why it alone is not enough |
|----------|-----|---------------------------|
| **Order** | one mapper per output file checks keys are non-decreasing; one reducer checks that each file's first key follows the previous file's last key | passes even if records were dropped |
| **Preservation** | per-record CRC32 summed into a 128-bit accumulator; addition commutes, so sorting must not change the sum | passes even if nothing was sorted |

Interpretation is inverted from the usual convention: **an empty output
directory is a pass.** Any content is a problem report such as
`misorder in <file> between …` or `bad key partitioning: …`.

The check is scale-independent, so the 1 GB run proves the same property as a
100 TB run. Known kit issue: HSValidate can throw `IndexOutOfBoundsException`
(MAPREDUCE-6635); the kit's user guide lists map/reducer combinations that avoid
it, and those assume a real cluster.

## Parameters

| Parameter | Kit default | Here | Note |
|-----------|-------------|------|------|
| `NUM_MAPS` | 768 | 4 | 4 vcores |
| `NUM_REDUCERS` | 768 | 4 | the main tuning knob for HSSort |
| Scale | ≥ 100 GB via driver | 1 GB | fits the VM |
| Replication | ≥ 3 | 1 | one node |

Overlay file: [`conf/kit/Benchmark_Parameters.sh`](../conf/kit/Benchmark_Parameters.sh).

## Why this workload suits a constrained VM

HSGen is cheap and write-bound, HSSort stresses memory, local disk and the
shuffle path at once, and HSValidate is read-bound. The three phases therefore
load different resources, which makes configuration effects (container size,
reducer count, concurrent tasks) visible even at 1 GB.
