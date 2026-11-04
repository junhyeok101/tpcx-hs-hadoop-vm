# TPCx-HS Milestone 2 — System Architecture Design & Build

Single-node Hadoop cluster built to run the TPCx-HS v2.0.3 benchmark kit, with
a 1 GB HSGen dataset generated, loaded into HDFS and verified.

**Status: complete.** Milestone 3 (HSSort / HSValidate performance measurement)
is deliberately out of scope here; the cluster is left running and ready for it.

---

## 1. Environment (measured, not assumed)

| Item | Value | How checked |
|------|-------|-------------|
| Host | macOS + UTM virtual machine | given |
| Guest OS | Ubuntu 22.04.5 LTS (Jammy) | `/etc/os-release` |
| Kernel | 5.15.0-187-generic | `uname -a` |
| Architecture | **aarch64 (ARM64)** | `uname -m` |
| Hostname | `jihopc` | `hostname` |
| CPU | 6 vCPU | `nproc` |
| RAM | 3.8 GiB total, ~1.0-1.2 GiB free with the cluster up | `free -h` |
| Swap | 3.8 GiB | `free -h` |
| Disk | 30 GB volume, **11 GB free** after build | `df -h /` |
| Java | Eclipse Temurin **OpenJDK 1.8.0_504** (aarch64) | `java -version` |
| Hadoop | Apache **3.3.6**, `linux-aarch_64` build | `hadoop version` |
| Kit | **TPCx-HS v2.0.3**, MapReduce (MR2) jar | `VERSION.txt` |
| Spec | TPCx-HS Specification v2.0.3 | `TPCx-HS Specification.docx` in the kit |

Two numbers differed from the brief and are worth noting: free disk was
**13 GB** at the start (not ~15 GB), and usable RAM is well under half the
nominal 3.8 GiB because the VS Code server is resident. Every memory setting
below follows from that second number. Grafana and InfluxDB were also resident
until they were removed partway through (see §12).

### Why these versions

- **aarch64 throughout.** Hadoop publishes a separate
  `hadoop-3.3.6-aarch64.tar.gz` with real ARM64 native libraries;
  `hadoop checknative -a` confirms `libhadoop.so.1.0.0` loads. The generic
  x86 tarball would have run Java-only codecs.
- **JDK 8, not 11.** The kit's jar is Java 7 bytecode
  (`HSGen.class` major version 51, manifest `Created-By: 1.7.0_09`). JDK 8 runs
  it directly and is a fully supported Hadoop 3.3.6 runtime; JDK 11 adds risk
  for no benefit here.
- **No root.** `sudo` on this VM requires a password, so everything is
  installed under `$HOME` (`~/opt`) rather than `/usr/local`. This is why the
  kit's own driver script cannot be used unmodified (see §6).

---

## 2. Node configuration

One host, pseudo-distributed: five daemons in five JVMs over loopback.

| Daemon | Heap | Role |
|--------|------|------|
| NameNode | 512 MB | Namespace + block map. RPC on `localhost:8020`, UI on `:9870`. |
| DataNode | 256 MB | Stores blocks on the ext4 volume. The only bulk-data mover. |
| SecondaryNameNode | 256 MB | Merges the edit log into new fsimage checkpoints. Pinned to `localhost:9868`. |
| ResourceManager | 384 MB | Scheduler; owns the 2560 MB / 4 vcore container pool. |
| NodeManager | 384 MB | Launches containers, enforces memory, serves shuffle. |

See [`docs/DESIGN.md`](docs/DESIGN.md) for the component/data-flow write-up
intended for the report and slides.

---

## 3. Building this on a fresh VM

Everything below is derived at run time from `$HOME` and the current username,
so a teammate does **not** need to be called `jiho` or use the same paths. The
Hadoop XML files use `${user.home}` and `${user.name}`, which Hadoop's
`Configuration` class expands from Java system properties; the shell scripts
use `$HOME` and `$(id -un)`.

### 3.1 Provision the VM

Settings that the committed configuration assumes:

| | Value | If you change it |
|---|---|---|
| Hypervisor | UTM on macOS (Apple Silicon) | any; only the guest matters |
| Guest image | **Ubuntu Server 22.04 LTS, arm64** | an x86_64 guest needs different tarballs — see §3.2 |
| vCPU | 4–6 | <4: lower `yarn.nodemanager.resource.cpu-vcores` and `NUM_MAPS` |
| RAM | **4 GB** | <3.5 GB: lower `yarn.nodemanager.resource.memory-mb` and the daemon heaps |
| Swap | ≥ 2 GB | the container pool deliberately oversubscribes RAM |
| Disk | **30 GB** (≥ 10 GB free after the OS) | <6 GB free: not enough for a 1 GB run plus the sort |
| Packages at install | tick **OpenSSH server** | otherwise `apt install -y openssh-server` before step 3.3 |

Root is not required — everything installs under `$HOME`. The only privileged
step is installing `openssh-server` if the image lacks it.

### 3.2 Get the repository and the kit

Everything this project owns lives under a single root, `~/project`, so it can
be inspected, backed up or deleted as one unit and `$HOME` stays clean:

```
~/project/
├── tpcxhs-m2/              this repository
├── TPCx-HS_Kit_v2.0.3/     the kit (not committed -- see below)
├── opt/                    java8/ and hadoop/ (installed by 01-install.sh)
└── hadoop-data/            nn/ dn/ tmp/ logs/ pids/ yarn/ (cluster state)
```

```bash
mkdir -p ~/project && cd ~/project
git clone <this repo> tpcxhs-m2        # or copy the directory across
cd tpcxhs-m2
```

`opt/` and `hadoop-data/` are created for you. To use a different root, set
`TPCXHS_ROOT` (it defaults to `$HOME/project`) **and** update the
`${user.home}/project/...` paths in `conf/hadoop/*.xml` — Hadoop XML can only
expand Java system properties, not shell variables, so that one duplication is
unavoidable.

The TPCx-HS kit is **not** in this repository — its EULA forbids
redistribution (§4 below). Download it from <https://www.tpc.org/tpcx-hs/> and
unpack it so the runtime suite sits at
`~/project/TPCx-HS_Kit_v2.0.3/TPCx-HS-Runtime-Suite`, or put it anywhere and
`export KIT_HOME=/path/to/TPCx-HS-Runtime-Suite`.

On a non-aarch64 guest, edit `HADOOP_VERSION`, `HADOOP_TARBALL`,
`HADOOP_MIRRORS`, `HADOOP_SHA512` and `JDK_URL` at the top of
`scripts/00-env.sh` — Hadoop publishes `hadoop-<ver>.tar.gz` for x86_64 and
`hadoop-<ver>-aarch64.tar.gz` for ARM64.

### 3.3 Run the build

```bash
cd ~/project/tpcxhs-m2
./scripts/00-preflight.sh      # checks arch, CPU, RAM, swap, disk, commands,
                               # sshd, the kit, and every download mirror.
                               # Fix anything marked FAIL before continuing.
./scripts/01-install.sh        # fetch + unpack JDK 8 and Hadoop, apply conf/
./scripts/01b-setup-ssh.sh     # passwordless ssh to localhost
./scripts/02-format-hdfs.sh    # format the NameNode (refuses if data exists)
./scripts/03-start-cluster.sh  # start HDFS + YARN, wait for safe mode, check jps
./scripts/05-hsgen.sh 1        # generate 1 GB with the kit's HSGen
./scripts/07-hsdatacheck.sh    # the kit's HSDataCheck + size/record accounting
./scripts/06-verify.sh "/user/$(id -un)/TPCx-HS-benchmark/HSsort-input"
./scripts/04-stop-cluster.sh   # stop (data is kept)
```

Expect roughly: 5–15 min for `01-install.sh` (a 711 MB tarball), seconds for
the rest, ~30 s for HSGen at 1 GB.

`scripts/00-env.sh` holds the shared environment and is sourced by every other
script. Run `01-install.sh` again at any time — it is idempotent: it skips a
download whose checksum already matches, and will not append its block to
`hadoop-env.sh` twice.

### 3.4 Things that will bite you

These were all hit during the original build and are now handled by the
scripts, but they explain the non-obvious code:

- **`dlcdn.apache.org` is slow and stalls.** Measured at ~180 KB/s and then
  hanging outright. `00-env.sh` lists four mirrors and `01-install.sh` tries
  them in order with `--read-timeout` so a stall moves to the next one rather
  than hanging forever. `mirror.kakao.com` served the same file at ~1.8 MB/s.
- **No `openssh-server` means no cluster.** `start-dfs.sh` SSHes into every
  host in `etc/hadoop/workers`; with no sshd, zero daemons start and the error
  is not obvious. `00-preflight.sh` fails loudly on this.
- **`sudo` may need a password.** It does on this VM, which is why nothing
  installs to system paths.

### Integrity

The Hadoop tarball was checksum-verified before use:

```
sha512sum hadoop-3.3.6-aarch64.tar.gz
b0a485c5ae0d97b08285bb83a3dd78b834153b2bd53f96ac301852862ccaff139f2c547aee...
# matches https://dlcdn.apache.org/.../hadoop-3.3.6-aarch64.tar.gz.sha512
```

(The published checksum file labels itself `hadoop-3.3.6-RC1.tar.gz` — Apache's
release-candidate naming. The hash is the one for the aarch64 artifact.)

---

## 4. Configuration

Committed under [`conf/hadoop/`](conf/hadoop/) and copied into
`$HADOOP_HOME/etc/hadoop` by `01-install.sh`. The non-obvious settings:

| Setting | Value | Reason |
|---------|-------|--------|
| `fs.defaultFS` | `hdfs://localhost:8020` | **Not 9000.** The kit's `HSDataCheck` class hardcodes `hdfs://127.0.0.1:8020` (`TPCx-HS-SRC-MR2/HSDataCheck.java:34`). 8020 is also Hadoop's own default. Matching it makes the kit's verification tool work without patching kit source. |
| `dfs.replication` | `1` | Forced by having one node. See §8. |
| `dfs.blocksize` | 128 MB | Default; a 1 GB dataset spans ~7.5 blocks. |
| `dfs.datanode.du.reserved` | 2 GB | Stops HDFS from filling the root filesystem. |
| `dfs.namenode.secondary.http-address` | `localhost:9868` | Left at the `0.0.0.0` default, `start-dfs.sh` rewrites it to `$(hostname)` and ssh's to `jihopc`, which was not an authorised host — the SecondaryNameNode silently failed to start. |
| `yarn.nodemanager.resource.memory-mb` | 2560 | The container pool. Was 2048 while Grafana and InfluxDB were resident; raised after they were removed (see §12). |
| `yarn.scheduler.maximum-allocation-mb` | 1024 | Caps any single container. |
| `yarn.nodemanager.resource.cpu-vcores` | 4 | 6 vCPUs, 2 left for the OS and HDFS daemons. |
| `yarn.nodemanager.vmem-check-enabled` | `false` | The JVM reserves a large virtual address space on aarch64; the default 2.1× vmem ratio kills healthy containers. Physical-memory enforcement stays on. |
| `mapreduce.map.memory.mb` / `java.opts` | 768 / `-Xmx600m` | Heap held at ~78% of the container so JVM overhead does not trip the pmem check. |
| daemon heaps | see `hadoop-env-tpcxhs.sh` | Hadoop's 1 GB-per-daemon default × 5 daemons would exceed physical RAM. |

Kit settings are in [`conf/kit/Benchmark_Parameters.sh`](conf/kit/Benchmark_Parameters.sh)
— a parameter **overlay** written for this repo, not a copy of the kit's file.
**The kit directory itself was not modified.**

> **Licence:** no TPCx-HS kit material is committed to this repository. The kit
> EULA v2.1 clause 4.a forbids reproducing or distributing kit files, and
> 4.a.(3) forbids contributing them to third-party projects. `.gitignore`
> blocks them. Get the kit from <https://www.tpc.org/tpcx-hs/>.

| Kit parameter | Shipped | Here | Reason |
|---------------|---------|------|--------|
| `HADOOP_USER` / `HDFS_USER` | `root` | `$(id -un)` | No root. The HDFS superuser is whichever account formatted the NameNode, i.e. whoever runs the build. |
| `NUM_MAPS` | 768 | 4 | 4 vcores available. 768 maps would serialise into ~192 waves. |
| `NUM_REDUCERS` | 768 | 4 | Ignored by HSGen (map-only), used by HSSort in M3. |

---

## 5. SSH

Hadoop's `start-dfs.sh` / `start-yarn.sh` ssh into every host in
`etc/hadoop/workers` (here: `localhost`). `01b-setup-ssh.sh` creates a
**dedicated** key (`~/.ssh/id_rsa_hadoop`) rather than touching any default
identity, refuses to overwrite an existing key, and authorises
`localhost`, `127.0.0.1`, `0.0.0.0` and the machine's own short hostname
(`$(hostname)` — `jihopc` on this VM), which is the one `start-dfs.sh` needs.

The key has an empty passphrase because the `sbin` scripts cannot answer a
prompt. It is authorised for loopback only, and no key or passphrase is stored
in this repository — `.gitignore` excludes `id_rsa*` and `*authorized_keys*`.

---

## 6. HSGen run

### Why not `./TPCx-HS-master.sh -m -g 1`

The kit's driver was read before being used (`USER_GUIDE.txt`,
`TPCx-HS-master.sh`). Four findings ruled out running it as-is:

1. **Its smallest scale factor is 100 GB.** `-g 1` sets
   `hssize=1000000000` *records* × 100 B = 100 GB
   (`TPCx-HS-master.sh:103`), and the guide labels it "for test purpose only,
   not a valid Scale Factor". This VM has ~10 GB of HDFS capacity. No `-g`
   option fits.
2. **It runs the full suite twice** — HSGen → HSSort → HSValidate, `for i in
   seq 1 2` — which is Milestone 3 scope.
3. **It deletes data without asking:** each run begins with
   `hadoop fs -rm -r -skipTrash /user/$HADOOP_USER/$HDFS_BENCHMARK_DIR/*`.
4. **It needs `sudo`** (`sudo -u $HDFS_USER hadoop fs -mkdir ...`), which
   requires a password here.

So `scripts/05-hsgen.sh` invokes the kit's `HSGen` class directly, with the
driver's exact command line and the kit's parameters — same benchmark code,
smaller record count, nothing destroyed:

```bash
hadoop jar TPCx-HS-master_MR2.jar HSGen \
    -Dmapreduce.job.maps=4 -Dmapreduce.job.reduces=4 \
    -Dmapred.map.tasks=4   -Dmapred.reduce.tasks=4   \
    10000000 /user/jiho/TPCx-HS-benchmark/HSsort-input
```

### Scale

A record is 100 bytes — `KEY_LENGTH 10 + VALUE_LENGTH 90`
(`TPCx-HS-SRC-MR2/HSInputFormat.java:55-57`) — so `records = GB × 10,000,000`.
**1 GB = 10,000,000 records.** `HSGen` is map-only:
`HSGen.java:300` calls `job.setNumReduceTasks(0)`.

### Result

```
Map input records   = 10,000,000
Map output records  = 10,000,000
HDFS bytes written  = 1,000,000,000
Launched map tasks  = 4
HSGen$Counters CHECKSUM = 21472776955442690
real    0m28.356s
```

The CHECKSUM is what HSValidate compares against in Milestone 3 — keep it.

---

## 7. Verification

HDFS path: `/user/$(id -un)/TPCx-HS-benchmark/HSsort-input` — the transcript
below is the real output from this VM, where that resolved to `/user/jiho/...`:

```
$ hdfs dfs -ls /user/jiho/TPCx-HS-benchmark/HSsort-input
-rw-r--r--   1 jiho supergroup          0 ... /_SUCCESS
-rw-r--r--   1 jiho supergroup  250000000 ... /part-m-00000
-rw-r--r--   1 jiho supergroup  250000000 ... /part-m-00001
-rw-r--r--   1 jiho supergroup  250000000 ... /part-m-00002
-rw-r--r--   1 jiho supergroup  250000000 ... /part-m-00003

$ hdfs dfs -du -h -s /user/jiho/TPCx-HS-benchmark/HSsort-input
953.7 M  953.7 M  /user/jiho/TPCx-HS-benchmark/HSsort-input
```

953.7 MiB = 1,000,000,000 bytes exactly (the kit counts in decimal GB).

| Check | Result |
|-------|--------|
| `jps` — all 5 daemons | PASS |
| Kit `HSDataCheck.sh` (`hdfs dfs -ls`) | PASS — 4 parts + `_SUCCESS` |
| Kit `HSDataCheck` class | PASS — lists all 5 files via `hdfs://127.0.0.1:8020` |
| Byte count | PASS — 1,000,000,000 B = 10,000,000 × 100 B |
| `hdfs fsck /` | HEALTHY — 0 corrupt, 0 missing, 0 under-replicated |
| `yarn node -list` | 1 node RUNNING (`jihopc:36691`) |
| Record format | PASS — first record is exactly 100 B and matches `GenSort.generateRecord` field for field |
| Independent regeneration | PASS — records rebuilt outside Hadoop are **byte-identical** to HDFS, and the full checksum recomputes (below) |

```
$ hdfs dfs -cat .../part-m-00000 | head -c 100 | od -c
0000000   J   i   m   G   r   a   y   R   I   P  \0 021   0   0   0   0
...
0000144                                        <- octal 144 = 100 bytes
```

`JimGrayRIP` is **not** a literal in the kit — `grep -rn -i 'jim\|gray\|RIP'`
over `TPCx-HS-SRC-MR2/*.java` finds nothing. It is the *computed* 10-byte key of
record 0: `generateRecord` uses the high 10 bytes of the 128-bit random value
from `Random16.skipAhead(0)` as the key (`GenSort.java:43-45`), and the `\0 021`
immediately after it is the `recBuf[10]=0x00, recBuf[11]=0x11` break
(`GenSort.java:48-49`). The rest of the record follows the same source: 32 bytes
of ASCII-hex record number, a `0x88 0x99 0xAA 0xBB` break, 48 bytes of filler,
then `0xCC 0xDD 0xEE 0xFF`. So the string is evidence that the generator's
random sequence started at record 0 as intended — not a marker the kit stamps in.

### Independent regeneration

HSGen's output is a deterministic function of the record number
(`Random16.skipAhead(rowId)`, `HSGen.java:221-226`), so the dataset can be
rebuilt without Hadoop and compared byte for byte. The kit's own `GenSort` was
compiled standalone — it needs only `Random16`, `Unsigned16` and Hadoop's
`PureJavaCrc32` — and checked against the live dataset:

```bash
javac -cp "$(hadoop classpath)" -d . GenSort.java Random16.java Unsigned16.java

# records 0-4 (500 B), generated locally, vs. the real HDFS bytes
java -cp ".:$(hadoop classpath)" GenSort -c -b0 5 local5.bin
hdfs dfs -cat "/user/$(id -un)/TPCx-HS-benchmark/HSsort-input/part-m-00000" \
    | head -c 500 > hdfs5.bin
cmp local5.bin hdfs5.bin        # identical
sha256sum local5.bin hdfs5.bin  # both 3ca78c2a1d3cad671dc14a944f17706b
                                #       33ec4357447c063cffba62d62eaaf240

# the whole 1 GB re-checksummed, generated data discarded
java -cp ".:$(hadoop classpath)" GenSort -c -b0 10000000 /dev/null
# 4c49607ac53602  =  21472776955442690  -- matches HSGen's counter in section 6
```

This is a stronger check than looking for a magic string: the dataset is
reproducible from the record count alone, and the CHECKSUM that Milestone 3
will compare against is confirmed independently of the MapReduce run that
produced it.

### Final disk state

```
$ df -h /
/dev/mapper/ubuntu--vg-ubuntu--lv   30G   18G   11G  62% /

$ hdfs dfs -df -h /
hdfs://localhost:8020  27.8 G  961.7 M  10.8 G  3%
```

Re-measured after the monitoring stack was removed (§12). Immediately after the
M2 build, with Grafana and InfluxDB still resident, the same two commands
reported `20G used / 9.2G avail / 68%` and `9.1 G` of HDFS capacity.

### Why the dataset stayed at 1 GB

HSSort needs roughly **3× the input** (HDFS input + local spill + HDFS output).
Against 11 GB free (9.2 GB before the monitoring stack was removed):

| Input | Sort needs | Left over | Verdict |
|-------|-----------|-----------|---------|
| 1 GB | ~2 GB | ~9 GB | comfortable — **chosen** |
| 2 GB | ~4 GB | ~7 GB | safe |
| 3 GB | ~6 GB | ~5 GB | now viable, but leaves little slack for logs and retries |

1 GB is kept so Milestone 3 has room to work, and HSGen takes only 28 s if a
larger set is wanted later. `05-hsgen.sh` enforces the 3× rule before
generating anything and refuses to overwrite an existing dataset.

---

## 8. Known limitations and deviations from the specification

1. **`dfs.replication = 1`, spec requires ≥ 3.** A single node cannot hold
   three independent replicas. This is the headline non-compliance.
2. **Scale factor far below the minimum.** The smallest *valid* TPCx-HS scale
   factor is 1 TB; the smallest the kit's driver even offers is 100 GB. This
   run is 1 GB — three orders of magnitude below, and chosen only to fit the VM.
3. **Single node, so no cluster data distribution.** No rack awareness, no
   network shuffle between hosts, no node-failure behaviour to observe.
4. **The kit's driver was not used.** HSGen was invoked directly for the four
   reasons in §6. No performance metric (HSph@SF) is produced or claimed.
5. **Cluster Validation Suite skipped.** It requires `clush`/`pdsh`, which are
   meaningless on one node (and would need root to install).
6. **Memory is oversubscribed.** The 2560 MB container pool overlaps swap, and
   ~1.7 GB of RAM is held by the VS Code server. Milestone 3 sort timings will
   be pessimistic and should not be compared against published results.
7. **Installed under `$HOME`, not system paths**, because `sudo` needs a
   password. Functionally equivalent, but not how a production cluster is laid
   out.
8. **`yarn.nodemanager.vmem-check-enabled=false`** is a deviation from Hadoop
   defaults, needed because of aarch64 JVM virtual-memory reservation.

**Nothing here should be published or reported as a TPCx-HS result.** It is a
valid architecture and functional-correctness exercise, which is what
Milestones 2 and 3 ask for.

---

## 9. Handover: what Milestone 3 does next

The cluster is left **running** with the 1 GB dataset in place.

1. Bring the cluster up if needed: `./scripts/03-start-cluster.sh`
2. Decide the input size — **2 GB is the comfortable choice, 3 GB is now
   reachable** after the extra 1.8 GB was freed, see §7. To change it:
   `hdfs dfs -rm -r -skipTrash "/user/$(id -un)/TPCx-HS-benchmark/HSsort-input"`
   then `./scripts/05-hsgen.sh 2`
3. Run HSSort with the kit's command line
   (`TPCx-HS-master.sh:265`):
   ```bash
   hadoop jar $KIT/TPCx-HS-master_MR2.jar HSSort \
       -Dmapreduce.job.maps=4 -Dmapreduce.job.reduces=4 \
       "/user/$(id -un)/TPCx-HS-benchmark/HSsort-input" \
       "/user/$(id -un)/TPCx-HS-benchmark/HSsort-output"
   ```
   Expect to tune `NUM_REDUCERS` — HSSort is the memory-hungry step and the one
   this VM is tight for.
4. Run HSValidate (`TPCx-HS-master.sh:299`) and compare against the HSGen
   CHECKSUM recorded in §6. Note the kit's known
   `IndexOutOfBoundsException` issue (MAPREDUCE-6635) in `USER_GUIDE.txt`.

   What HSValidate actually asserts — two independent properties, and both are
   needed, since order alone would pass even if records were dropped and the
   checksum alone would pass even if nothing were sorted:

   | Property | How | Source |
   |----------|-----|--------|
   | Ordering | one mapper per file checks keys are non-decreasing; the single reducer checks the `:begin`/`:end` keys of adjacent files join up | `HSValidate.java:85-89`, `:137-143` |
   | Preservation | per-record CRC32 summed into a 128-bit accumulator — **addition commutes, so sorting must not change the sum** | `HSValidate.java:92-96` vs `HSGen.java:232-235` |

   Judging the result is inverted from the usual convention: **an empty output
   directory is the pass.** Any content is the problem report
   (`misorder in <file> between ...` or `bad key partitioning: ...`) — see the
   class comment at `HSValidate.java:48-49`.

   This logic is scale-independent. The 1 GB dataset makes the run
   unpublishable (§8) but does not weaken the correctness proof at all: it is
   mathematically the same check that runs at 100 TB.
5. Watch `df -h /` between phases; `05-hsgen.sh`'s 3× guard does not cover a
   sort you launch by hand.

---

## 10. Repository layout

```
tpcxhs-m2/
├── README.md                       this file
├── .gitignore                      excludes binaries, HDFS data, keys
├── conf/
│   ├── hadoop/                     core/hdfs/yarn/mapred-site, hadoop-env, workers
│   └── kit/                        our parameter overlay (no kit files — see EULA note)
├── scripts/                        00-env, 00-preflight, 01-install, 01b-ssh,
│                                   02-format, 03-start, 04-stop, 05-hsgen,
│                                   06-verify, 07-hsdatacheck,
│                                   99-remove-monitoring-stack (optional)
├── docs/
│   ├── DESIGN.md                   components, roles, data flow (for the report)
│   ├── KIT-INTEGRATION.md          kit location, driver findings, scale arithmetic
│   └── architecture-summary.html   the slide/report page (§11)
├── downloads/                      tarballs — gitignored
└── logs/                           HSGen run logs — gitignored
```

Paths outside the repo, all siblings under `~/project` and none privileged:
`~/project/opt/{java8,hadoop}` (software),
`~/project/hadoop-data/{nn,dn,tmp,logs,pids,yarn}` (cluster state),
`~/project/TPCx-HS_Kit_v2.0.3` (the kit, unmodified, not committed).
`TPCXHS_ROOT` in `scripts/00-env.sh` is the single knob for that root.

Nothing in `conf/` or `scripts/` contains an absolute `/home/<user>` path: the
XML files use `${user.home}` / `${user.name}` (expanded by Hadoop's
`Configuration`) and the shell uses `$HOME` / `$(id -un)`.

---

## 11. Presentation material

[`docs/architecture-summary.html`](docs/architecture-summary.html) is a
self-contained page covering the same ground as this README with two diagrams
drawn for slides: the HSGen data flow (showing the absent shuffle stage) and
HSSort's three on-disk copies (showing where the 3× rule comes from). Open it
in a browser, or view the published copy at
<https://claude.ai/code/artifact/2fb9743e-8209-4cd2-9fd7-df390fc72307>.

---

## 12. Change log after the initial build

**2026-11-04 — Grafana and InfluxDB removed from the VM.** They were holding
~288 MB of resident memory and ~1.8 GB of disk. Removal was requested by the
VM owner, who ran the privileged commands (this account has no passwordless
`sudo`, and no credential was ever handled by the build scripts).

The removal needed one repair. `influxdb2`'s maintainer script
`/var/lib/dpkg/info/influxdb2.postrm` ends with

```bash
function disable_systemd {
    systemctl disable influxdb
}
```

with no error tolerance. An earlier partial removal had already deleted
`influxdb.service`, so `systemctl disable influxdb` exited non-zero, that
became the script's exit status, and `dpkg` aborted the removal — leaving the
package half-configured and blocking all later `apt` operations. Appending
`exit 0` to the script let `dpkg --purge` complete; nothing was lost, because
the postrm's only real cleanup (`rm -f /etc/default/influxdb`) runs *before*
the failing line. `dpkg --purge` rather than `apt purge` was used because the
installed Grafana 13.1.1 is no longer in the configured repository, so apt
could not resolve its version (`W: Can not find PkgVer for 'grafana'`).

Consequent config change: `yarn.nodemanager.resource.memory-mb` 2048 → 2560.
Verified afterwards that YARN reports `<memory:2560, vCores:4>`, all five
daemons restart cleanly, and the 1 GB dataset is intact and `fsck` HEALTHY.

This has no bearing on reproducing the build: `scripts/01-install.sh` through
`07-hsdatacheck.sh` never touched those packages, and
`scripts/99-remove-monitoring-stack.sh` is kept outside the numbered sequence
because it is optional and destructive.
