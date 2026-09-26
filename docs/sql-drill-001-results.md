# Azure SQL failover group drill 001: results

Measured on 2026-09-26. West US (primary) and Central US (secondary), one Standard S0
database in a failover group with a customer-managed (manual) policy, under a continuous
write load of about 10 inserts per second. Targets were committed in
[`2720ae5`](https://github.com/gkoufie1/azure-dr-drill/commit/2720ae5) before any
resource existed. Procedure and definitions: [`runbooks/sql-failover-drill.md`](runbooks/sql-failover-drill.md).

## Results

| | Target | Measured | Result |
|---|---|---|---|
| **Forced failover: RTO** | 60 s | **12.90 s** command to first write back (client outage window **5.18 s**) | **Met** |
| **Forced failover: RPO** | 5 s (my own choice; Microsoft documents no number) | **21 rows lost, about 2.3 s of writes** | **Met** |
| **Planned failover: rows lost** | 0 | **0** of 5,838 rows acknowledged in run 3 before the forced failover was issued | **Met** (a correctness check, not a performance target) |
| Planned failover: outage | no target | **6.67 s** | |

Both failovers were single runs. They show how failover behaves, not a benchmark.

## What was measured, and how

- **The writer** inserts one numbered, timestamped row about every 100 ms through the failover
  group's read-write listener and logs every outcome (`ACK` or `FAIL`) to a CSV. `analyze.py`
  compares every acknowledged sequence number in the CSV against the rows that exist in the
  database afterwards.
- **Rows lost** = acknowledged by the database but absent afterwards. **RPO** = client time of the
  last lost row minus client time of the newest surviving row before the gap (one machine's
  clock, so no skew).
- **Outage window** = last `ACK` before the errors to the first `ACK` after them. **RTO** = failover
  command issued to that first `ACK` after the outage.

## Timeline (UTC, 2026-09-26)

| Time | Event |
|---|---|
| 16:40:05 to 16:47:23 | `terraform apply`: 9 resources; the failover group took 3 min 19 s, mostly creating the geo-secondary |
| 17:00:39 | Writer run 1 starts |
| 17:07:43.787 | Planned failover to Central US issued; the command returned at 17:08:41.557 |
| about 17:08:02 | Writer run 1 goes silent (the tool hung, see below) |
| 17:10:12 | Writer run 2 starts on the new primary (Central US), resuming at row 3,817 |
| 17:17:18.841 | Planned failback to West US issued; returned 17:17:54.335 |
| about 17:17:31 | Writer run 2 stops writing (driver stuck, see below); killed by hand about 17:22 |
| 17:22:39 | Writer run 3 (process-supervised) starts |
| **17:23:01.471** | **Planned failover to Central US issued** (valid measurement); returned 17:23:36.373 |
| **17:33:13.284** | **Forced failover to West US issued** (`--allow-data-loss`); returned 17:33:27.918 |
| 17:33:21.002 | Last write acknowledged before the switch (row 13,807) |
| 17:33:26.185 | First write acknowledged after the switch (row 13,808) |
| 17:41:12 | Teardown starts |
| 17:44:59 | `terraform destroy` finishes; verified gone against Azure |

## The two failovers in detail

### Planned failover (run 3, 17:23:01)

- Replication lag read **0 s** just before.
- The writer kept succeeding for **9.2 s** after the command (Azure synchronizes the secondary
  first), then saw errors from 17:23:10.7 to 17:23:13.6, then wrote again at 17:23:17.2.
- **Outage 6.67 s.** The command-to-first-write figure (15.76 s) includes those 9 seconds of
  still-working writes, so the outage is the meaningful downtime.
- **0 rows lost.** Two of the errors were *"the database is read-only"*: the client reconnected to
  the old primary, which had already become the secondary, because the listener's DNS record
  (30 s TTL) still pointed at it. That DNS effect is part of the measured outage.

### Forced failover (run 3, 17:33:13)

- Replication lag read **0 s** at 17:33:12.97, 0.3 s before the command.
- Writes kept being acknowledged by the old primary for **7.7 s** after the command, until the
  role switch took effect at about 17:33:21.0.
- The writer saw silence, its 3 s watchdog killed the connection worker at 17:33:24.0, and the first
  acknowledged write on the new primary came at 17:33:26.2.
- **Outage 5.18 s. RTO 12.90 s.**
- **21 acknowledged rows did not survive** (rows 13,787 to 13,807, acknowledged between
  17:33:18.76 and 17:33:21.00). Row 13,786 and everything before it survived, and row 13,808
  onwards were written to the new primary. **RPO about 2.32 s.**

## Caveats

- **Not a real outage.** The old primary was healthy when the failover was forced. This is the
  closest a subscription can simulate; it does not take a region down.
- **"Lag 0 s" did not mean "no loss".** The lag counter read 0 s just before the command, yet 21
  acknowledged rows were lost. Writes acknowledged in the last ~2.3 s before the switch had not
  reached the secondary. **That explanation is a hypothesis;** I did not test it, and I did not
  measure the lag during the window.
- **DNS and the writer's timeout are inside the numbers.** The listener has a 30 s DNS TTL and this
  machine has its own DNS cache; the writer's watchdog also kills a silent connection after 3 s. The
  measured RTO is "as seen from a client", not the service's internal switch time.
- **RTO definition, refined after the fact.** The runbook said "first successful write acknowledged
  by the new primary". The writer cannot see which server acknowledged a write, and writes kept
  succeeding on the old primary for several seconds after each command. I therefore took the RTO as
  the command time to the first acknowledged write *after the outage*. That is my interpretation, and
  it is disclosed here, not hidden. Read literally, the first acknowledged write after the command
  was immediate.
- **Non-paired regions.** West US and Central US are not a Microsoft pair, and Microsoft advises
  paired regions for failover groups. A worse RPO here could reflect that; I did not test a paired pair.
- **A small workload.** About 10 tiny inserts per second on an S0. Not representative of a busy database.
- **One run each.**

## The measurement tool failed twice before it worked

All three attempts are kept in `docs/evidence/`.

| Run | What happened | What it cost me |
|---|---|---|
| 1 (`writer-run1-planned-failover-HUNG.csv`) | The writer went silent during the first planned failover and logged **no errors**: the database driver's timeouts did not fire when the connection dropped. | No usable timing for that failover. Correctness still checked: 3,816 acknowledged rows, 3,816 present. |
| 2 (`writer-run2-planned-failback-DRIVER-STUCK.csv`) | I added a thread watchdog. It logged the failures but the driver stayed stuck and never reconnected for 4+ minutes, although a fresh process connected instantly, so the service was fine. My explanation (an abandoned stuck call blocks later connections in the same process) is a **hypothesis**. | No usable timing for the failback. 0 of 4,080 acknowledged rows lost. |
| 3 (`writer-run3-planned-and-forced-failover.csv`) | The writer now runs inserts in a separate worker **process**, and a supervisor kills it if it goes quiet. It survived both failovers. | The two measurements above come from this run. |

The planned failover was measured again only because of the tool defects; it has no target, so this
did not change what any target was judged against. The forced failover, which has the targets, was run
once, after the tool worked.

**One analysis error, also recorded.** My first saved `analysis-output.txt` reported a 615-second outage
for the planned failover, because the log by then contained the forced failover too and the analyzer
counted both. I added an `--until` option and regenerated it. The 6.67 s figure had been computed
correctly earlier, when the log held only the planned failover, and the regenerated output matches it.

## Other things observed

- After the forced failover the replication link sat in `SUSPENDED`, then `SEEDING`, then `CATCH_UP` while
  Azure re-synchronized the old primary as a secondary; about 10 minutes passed before it left
  `SUSPENDED`.
- Removing the leftover replication link during teardown failed with
  `GeoReplicationCannotBecomePrimaryDuringUndo` until the link left `SUSPENDED`; I polled and retried.
- The Central US activity log shows four failed `Update SQL database` events between 16:44 and 16:47
  (HTTP 404) while the secondary was being created. I saw only the status codes and did not investigate
  the cause.

## Cost

About 57 minutes of two Standard S0 databases (16:47 to 17:44 UTC; roughly $0.02 per hour each at published
prices), so **about $0.04. That is an estimate from published prices, not from billing data.** Servers, firewall
rules and the failover group have no charge of their own. The real figure will appear after billing data
catches up.

## Evidence

| File | What it shows |
|---|---|
| `docs/evidence/writer-run3-planned-and-forced-failover.csv` | Every insert outcome of the valid run |
| `docs/evidence/analysis-output.txt` | The computed numbers for both failovers |
| `docs/evidence/writer-run1-…-HUNG.csv`, `writer-run2-…-DRIVER-STUCK.csv` | The two failed measurement attempts |
| `screenshots/sql-fog-*.png` | The failover group's roles before, after the planned failover, and after the forced one |
| `screenshots/sql-activity-log-*.png` | The failover events in each server's activity log |

## Teardown

Failover group deleted, the leftover geo-replication link removed once it left `SUSPENDED`, then
`terraform destroy` (8 resources). Verified with direct requests: both servers return `ResourceNotFound`,
0 SQL servers in the subscription, Terraform state empty. Only the free Network Watchers remain.
