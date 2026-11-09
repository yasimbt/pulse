# M3 findings: history store

## Store design (`PulseCore/Store`)
- SQLite through GRDB 7.12.0, pinned exactly in `project.yml` (the generated project and its
  `Package.resolved` aren't committed). File: `~/Library/Application Support/Pulse/history.sqlite`,
  in WAL mode so reads don't wait for writes.
- Three tiers with the same columns, one row per time and one column per `SeriesID` (its raw
  value is the column name, so cases must never be renamed):
  `samples_raw` (1 h), `samples_10s` (24 h) and `samples_1m` (30 days), as in SPEC §3.
- Writes are buffered and done in one transaction every 30 s, which also averages completed
  buckets into the coarser tiers and deletes rows past retention. Quitting normally writes the
  buffer first; a crash or `kill` loses up to 30 s.
- Reads use the finest tier that reaches back to the start of the range, then finer tiers for the
  newest stretch the coarser tier hasn't averaged yet, then unwritten buffered rows.
- Only enabled modules are sampled, so history covers what's in the menu bar.
- Migrations: GRDB's `DatabaseMigrator`. Shipped migrations are never edited.

## Measurements
- **Size:** 30 days with every tier full and every series set: 6 MB (test
  `thirtyDaysOfHistoryStayFarUnder200MB`). Acceptance limit: 200 MB.
- **CPU:** combined menu-bar item with Power, Release, panels closed: 0.508% over 189 s with history
  on, against 0.495-0.503% before. The 30 s batched writes are within run-to-run noise.
- **Quit:** after a normal quit, the newest row was 2 s before quitting.
