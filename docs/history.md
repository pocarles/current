# History and accuracy

Current records interval deltas, not the counter value accumulated before launch. The recent graph reduces new observations to at most 361 ten-second peak bins in memory. Saves run in batches about once a minute, with extra batches on sleep, quit and uncertain/outage/recovery transitions. SQLite access runs on a dedicated actor.

Each interval contributes independently to three tiers. The tiers overlap, so a query must use one grain for each timestamp. Different grains may cover strictly disjoint ranges; overlapping totals must never be added.

| Grain | Retention | Fields |
| --- | --- | --- |
| Minute | Seven days | Bytes, observed peaks, observed/sleep/app-gap/unobserved/offline/uncertain seconds |
| Hour | 180 days | Same fields |
| UTC day | 100 years | Same fields |

Totals split proportionally across time boundaries with the last segment receiving any integer-byte remainder. Totals remain exact within each retained tier; allocation inside the sampled interval is an estimate. Each touched bucket keeps the interval's measured peak. An interval crossing a minute or date boundary does not reveal the exact timing of each packet.

`buckets` has a composite primary key of `grain,start`. `events` records launches, quits, sleep/wake, connection-state changes and recoveries. Events keep their latest 50,000 entries. `metadata` stores the end of the last saved observation. The first launch establishes an initial checkpoint; later event-only writes do not advance it. On launch, the time since that checkpoint is recorded in the separate app-gap field. It identifies an app session gap, which can include the last unsaved minute after a crash. Current cannot recover bytes transferred while closed or asleep. A crash can lose the last unsaved minute; the next launch labels that time as an app gap.

Observed zero traffic differs from sleep, app gaps and missing data while the app was running. Interface resets or changes conservatively mark the interval unobserved even when a surviving interface contributes some bytes. Offline seconds count only confirmed outage time while monitoring is active. The initial failure-confirmation interval is uncertain; outage duration ends when a valid check returns. Actual loss/recovery may precede the check by the probe cadence and timeout. Sleep closes the active health session instead of implying an overnight outage.

Minute/hour/day retention pruning runs at most daily. The 50,000-event cap is enforced on each event batch. Incremental vacuum reuses old pages. New databases use 4 KiB SQLite pages. Current sets a 16,384-page limit of about 64 MiB on its database connection, a small WAL checkpoint interval, and a journal-size limit. These are bounds and configuration, not a measured steady-size claim. An unusually long-lived database or excess events may eventually hit the page limit. Writes fail visibly rather than deleting retained daily history. Events have a 512-character detail limit.

Pruning saves its highest wall-clock reference atomically in `metadata.retention_reference`. Historical queries use that reference when selecting disjoint tiers, including after restart or clock correction. A clock set far ahead can expire detail early. Retained coarser summaries still provide totals, peaks and coverage; Current cannot reconstruct deleted fine timing. Older schema-3 databases without this metadata use their saved high-water checkpoint as the best available reference. A corrected clock can therefore leave charts at coarser resolution until it catches up. No table migration is required.

The database uses WAL and `synchronous=NORMAL`. An ordinary app crash preserves committed SQLite transactions; an OS crash or power failure may lose recent committed transactions. This is a personal traffic history, not a billing ledger. There is no every-second disk write.

## Migrations and backups

`PRAGMA user_version` is the schema version. Version 1 has traffic/coverage/outage buckets, events and metadata. Version 2 adds `uncertain` seconds with a zero default. Version 3 adds `app_gap` seconds. Legacy unobserved time remains unobserved because its cause cannot be recovered reliably. Migrations run in a transaction, preserve existing rows and reject databases from newer versions before changing their schema.

The backup command uses SQLite's backup API, so pending WAL contents are included. It flushes current observations first, copies to a temporary file beside the destination, and publishes the complete file atomically without replacing an existing file. A failed copy removes its temporary file. Export creates UTF-8 CSV with UTC daily rows and retained events. Both operations require a fresh destination and protect the active database from replacement. A full backup can be inspected with standard SQLite tools. To restore manually, quit Current, preserve the existing database and its WAL sidecars, then copy the backup into the default database location. An in-app restore flow is not implemented.

Clock changes, unusual virtual adapters, midnight/time-zone changes and disk-error recovery need more end-to-end soak testing. Today queries have both date bounds, so history from a future day cannot enter the totals after the clock moves back. A successful database write is never retried because a later display query fails; the display fallback retains bytes, peaks and every coverage field. Exports stop if pending readings cannot be saved. A failed final write cancels quitting and keeps pending observations in memory for retry. A force quit or power loss can still lose them. If unsaved data exceeds 3,600 observations, the oldest span becomes an explicit gap instead of silently disappearing. The focused tests cover tier aggregation, clock corrections, boundary byte conservation, UTC midnight, retention, a long sleep gap, migration, backup failures and CSV quoting. A 3,653-day fixture preserves totals, both peaks, downtime, app gaps and coverage through retention, backup and CSV export. A same-day event stress test verifies the cap stays exactly 50,000.

## Selected periods

The menu panel queries trailing elapsed intervals of one hour, 24 hours, 7 days or 30 days, or all available recorded history. Chart, totals and Peak follow this selection. Saved totals and longer charts refresh on open, on selection and after normal batched saves while open; the hour chart merges live observations. Saved-through and coverage details are in help text. Live hour peaks can include the unsaved minute, whereas totals reflect saved observations. It does not persist or query history every second.

At most three indexed SQLite aggregate queries combine disjoint ranges. The recent range uses minute buckets, the next uses hourly buckets, and older data uses daily buckets. Tier switches align to coarser UTC bucket boundaries inside the finer tier's retention window. Each timestamp contributes to exactly one tier. The menu panel never loads every daily row to build this summary; daily rows are loaded only for the independent History window.

Whole-bucket byte totals use integer sums. If an interval clips a bucket, the clipped part uses proportional totals and coverage because individual observation times are no longer retained. The UI states that partial-bucket totals are estimated. A peak from a clipped bucket can have occurred outside the interval; if it exceeds every fully included bucket's peak, the UI displays `Peak ≤` as an upper bound. A higher fully included peak is exact within the retained measurements. None of these peaks measure connection capacity.

The newest partially filled bucket is bounded by the earlier of the query end and saved observation marker, so its saved bytes are not reduced merely because the remainder of the minute has not happened yet. Future buckets are excluded after a backward clock change. If the saved checkpoint is ahead of the query, boundary timing is marked estimated. Two observations merged into one bucket on either side of a clock correction cannot be separated again; its saved byte total does not establish exact timing within that bucket.

These are read queries against schema 3. All time means available records, including preserved older summaries and known gaps. Current invents no observations before its first launch.

Longer charts group the same disjoint tiers in SQLite into approximately 360 peak bins (at most 361 measured bins plus bounded explicit missing ranges), aligned to the coarsest retained grain in the interval. Returned charts are bounded to 723 points, including gaps; they never materialize every historical row in Swift. SQL still scans the relevant indexed retained range on demand. Each bin preserves measured maxima and observed/missing coverage; a mixed gap bin is shaded and keeps measured peaks as dots. Lines never bridge unknown time. Observed zero remains a measurement. Longer ranges have coarser timing, not invented detail. The longer-period Peak and its upper-bound flag come from the same selected SQL summary. The hour Peak comes from the live chart and does not use the SQL boundary flag.

## Current observed interval and the hour graph

`Observed online` starts at a successful internet check during this app session. It advances only with valid awake counter samples and fresh successful checks. Sleep, app restart, missing/delayed samples, stale checks, path changes, paused probes and unsuccessful checks invalidate it. Recovery starts a new window. Periodic probes cannot establish uninterrupted service between checks. Earlier connection start is unknown; Current never invents the Mac's pre-app connection age.

The earlier accumulated online-time metadata is no longer read or restored. Normal batches remove its three optional keys (`online_since`, `online_seconds`, `online_gaps`) atomically. No DDL migration is required: schema 3, byte totals, peaks, coverage, outage events and retained history are preserved. Historical online coverage still belongs to each recorded interval; the menu's current window does not sum separate sessions.

On startup, the hour graph reads at most 61 indexed minute buckets bounded by the trailing hour and saved marker. New measurements merge into ten-second peak bins without new disk writes or per-second database reads. Missing rows and recorded gaps are shaded; mixed buckets preserve their measured peaks as dots without drawing lines through unknown time. Observed zero remains a measurement. Previously saved minute data has coarser peak timing than live ten-second bins. Clipping a boundary bucket retains its peak as an upper bound at that resolution. Selecting a longer period replaces this chart with its bounded saved-history query.

## Product rename

Current was developed as Traffic. The app retains bundle identifier `org.traffic.local`, the default `~/Library/Application Support/Traffic/traffic.sqlite` history location, `TRAFFIC_DATA_DIR` overrides, existing preference keys and the `TrafficSettings` saved window frame. The rename needs no database migration and does not copy or reset history. Internal Swift targets retain their original names. There was no public update feed to migrate.
