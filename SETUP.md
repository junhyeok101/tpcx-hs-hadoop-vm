# Setup: building the cluster and running the benchmark

How to rebuild this environment on a fresh VM and run the three TPCx-HS phases.
Written for a teammate who will run Milestone 3 measurements.

## 1. Environment (measured, not assumed)

| Item | Value | How checked |
|------|-------|-------------|
| Host | macOS + UTM virtual machine | given |
| Guest OS | Ubuntu 22.04.5 LTS (Jammy) | `/etc/os-release` |
| Kernel | 5.15.0-202-generic | `uname -r` |
| Architecture | **aarch64 (ARM64)** | `uname -m` |
| Hostname | `jihopc` | `hostname` |
| CPU | 6 vCPU | `nproc` |
| RAM | 7.7 GiB total, ~4.5 GiB available with the cluster idle (2026-11-05; 3.8 GiB at the original build) | `free -h` |
| Swap | 3.8 GiB | `free -h` |
| Disk | 30 GB volume, **9.4 GB free** on 2026-11-05 (11 GB after the build) | `df -h /` |
| Java | Eclipse Temurin **OpenJDK 1.8.0_504** (aarch64) | `java -version` |
| Hadoop | Apache **3.3.6**, `linux-aarch_64` build | `hadoop version` |
| Kit | **TPCx-HS v2.0.3**, MapReduce (MR2) jar | `VERSION.txt` |
| Spec | TPCx-HS Specification v2.0.3 | `TPCx-HS Specification.docx` in the kit |

Two numbers differed from the brief and are worth noting: free disk was
**13 GB** at the start (not ~15 GB), and usable RAM was well under half the
nominal 3.8 GiB because the VS Code server is resident. The original memory
settings followed from that second number. Grafana and InfluxDB were also resident
until they were removed partway through.

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
  kit's own driver script cannot be used unmodified.

---

---

## 2. Building this on a fresh VM

Everything below is derived at run time from `$HOME` and the current username,
so a teammate does **not** need to be called `jiho` or use the same paths. The
Hadoop XML files use `${user.home}` and `${user.name}`, which Hadoop's
`Configuration` class expands from Java system properties; the shell scripts
use `$HOME` and `$(id -un)`.

### 2.1 Provision the VM

Settings that the committed configuration assumes:

| | Value | If you change it |
|---|---|---|
| Hypervisor | UTM on macOS (Apple Silicon) | any; only the guest matters |
| Guest image | **Ubuntu Server 22.04 LTS, arm64** | an x86_64 guest needs different tarballs — see §2.2 |
| vCPU | 4–6 | <4: lower `yarn.nodemanager.resource.cpu-vcores` and `NUM_MAPS` |
| RAM | **8 GB** | <7 GB: lower `yarn.nodemanager.resource.memory-mb` and the daemon heaps |
| Swap | ≥ 2 GB | headroom for memory peaks |
| Disk | **30 GB** (≥ 10 GB free after the OS) | <6 GB free: not enough for a 1 GB run plus the sort |
| Packages at install | tick **OpenSSH server** | otherwise `apt install -y openssh-server` before step 2.3 |

Root is not required — everything installs under `$HOME`. The only privileged
step is installing `openssh-server` if the image lacks it.

### 2.2 Get the repository and the kit

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
redistribution (see the licence note in the README). Download it from <https://www.tpc.org/tpcx-hs/> and
unpack it so the runtime suite sits at
`~/project/TPCx-HS_Kit_v2.0.3/TPCx-HS-Runtime-Suite`, or put it anywhere and
`export KIT_HOME=/path/to/TPCx-HS-Runtime-Suite`.

On a non-aarch64 guest, edit `HADOOP_VERSION`, `HADOOP_TARBALL`,
`HADOOP_MIRRORS`, `HADOOP_SHA512` and `JDK_URL` at the top of
`scripts/00-env.sh` — Hadoop publishes `hadoop-<ver>.tar.gz` for x86_64 and
`hadoop-<ver>-aarch64.tar.gz` for ARM64.

### 2.3 Run the build

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

### 2.4 Things that will bite you

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

---

## 3. SSH

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

---

## 4. Running Milestone 3

The 1 GB dataset is in place. Check `jps` first, because the cluster may be down.

1. Bring the cluster up if needed: `./scripts/03-start-cluster.sh`
2. Decide the input size — **2 GB is the comfortable choice, 3 GB is now
   reachable** after the extra 1.8 GB was freed. To change it:
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
   this VM is tight for. Reducers are 1024 MB, so at most 3 run at once beside
   the 768 MB ApplicationMaster.
4. Run HSValidate (`TPCx-HS-master.sh:299`) and compare against the HSGen
   CHECKSUM (`21472776955442690`, see [workload/README.md](workload/README.md)). Note the kit's known
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
   unpublishable (see the README's deviations table) but does not weaken the correctness proof at all: it is
   mathematically the same check that runs at 100 TB.
5. Watch `df -h /` between phases; `05-hsgen.sh`'s 3× guard does not cover a
   sort you launch by hand.

---
