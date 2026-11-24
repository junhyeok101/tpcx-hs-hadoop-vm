# Raw run data (Milestone 3)

Per-run rows behind [../RESULTS.md](../RESULTS.md), copied unedited from
`logs/` after the runs. The full Hadoop job logs stay local (`logs/` is
git-ignored; they are large and regenerable).

| File | Written by | One row per |
|------|-----------|-------------|
| `M3-summary.tsv` | `scripts/08-hssort-validate.sh` | HSSort + HSValidate run, reducer experiment |
| `M3-maps-summary.tsv` | `scripts/09-hssort-validate-maps.sh` | HSSort + HSValidate run, map experiment |
| `M3-phases.tsv` | `scripts/10-phase-breakdown.sh` | HSSort run: setup / map / tail and counters |
| `M3-scale-summary.tsv` | `scripts/12-scalability-batch.sh` | HSGen, or HSSort + HSValidate run, scalability |
| `M3-scale-phases.tsv` | `scripts/10-phase-breakdown.sh scale` | HSSort run of the scalability experiments |

Times are seconds. `M3-summary.tsv` also holds the nine reducer-7 rows from
2026-11-21 18:35–19:40 that RESULTS.md excludes (host load; see "Discarded
runs" there); `M3-scale-summary.tsv` likewise keeps the first 1 GB / 2 GB pass
of 2026-11-24 14:26–14:42. They are kept so the exclusions can be checked.
