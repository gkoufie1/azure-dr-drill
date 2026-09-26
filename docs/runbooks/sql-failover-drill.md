# Runbook: Azure SQL failover group drill (West US to Central US)

## Objective

Fail an Azure SQL database over between regions with a **failover group**, under a
continuous write load, and measure the real recovery time (RTO) and the real data
loss (RPO). The ASR drill measured both for a VM; this one does it for a managed
database, where the failover is a service operation rather than a machine restart.

Two failovers run, in this order:

1. **Planned failover** (no data loss allowed): Azure synchronizes the secondary
   before switching roles. Expected loss is zero, so this is a **correctness check**,
   not a performance target.
2. **Forced failover** (`--allow-data-loss`): the secondary is promoted immediately,
   without waiting for the last changes to replicate. This is the closest simulation
   of a regional outage that a subscription can run; it does **not** take the region
   down.

## Targets, committed BEFORE anything is created

Written down and pushed before any resource exists, so the commit timestamp is the
evidence they were not chosen after seeing results.

- **Target RTO: 60 seconds** for the forced failover, measured as seen by the client:
  from the moment the failover command is issued to the first successful write
  acknowledged by the new primary. The source is Microsoft's documented figure for
  failover groups with a customer-managed policy: "typically less than 60 seconds".
- **Target RPO: 5 seconds** for the forced failover: the window of acknowledged writes
  that do not survive. **This number is my own choice.** Microsoft documents RPO only
  as "equal to or greater than 0, depending on data changes that have not been
  replicated", so there is no official figure to test against.
- **Planned failover: 0 rows lost.** A correctness check. Any loss is a failure of the
  drill or a finding, not a near miss.

## Definitions

- **Writer:** `sql-lab/writer.py` inserts one row every ~100 ms (about 10 per second)
  through the failover group's **read-write listener**, each with a sequence number
  and the client's UTC time, in autocommit mode. Every insert's outcome is logged to a
  CSV: `ACK` (the database confirmed the commit) or `FAIL` (with the error).
- **RTO (primary definition):** first `ACK` after the failover command was issued,
  minus the command's issue time. The client's outage window (last `ACK` before the
  first `FAIL`, to the first `ACK` after the last `FAIL`) is reported as well.
- **Rows lost:** the highest sequence number the writer saw `ACK`ed before the
  failover, minus the highest sequence number present in the new primary afterwards.
- **RPO:** the client UTC time of the last acknowledged row minus the client UTC time
  of the newest surviving row. All timestamps come from one machine's clock, so there
  is no clock skew between them.

## Known limits of the measurement, stated in advance

- **Non-paired regions.** West US and Central US are not a Microsoft region pair.
  Microsoft advises paired regions for failover groups because they perform better.
  They are used here because Azure SQL is only available in a few regions on this
  subscription (Step 1 of the README). A worse RPO here could be caused by this and
  would say nothing about paired regions.
- **DNS.** The listener is a DNS record with a 30-second TTL, and this machine has
  its own DNS cache. The measured RTO includes both, which is realistic for a client
  but is not the service's internal switch time.
- **A small, quiet database.** About 10 tiny inserts per second on a Standard S0 will
  probably replicate almost instantly, so zero rows lost is a plausible, valid result.
  To make a zero interpretable, the replication lag is read from
  `sys.dm_geo_replication_link_status` immediately before each failover and recorded.
- **One run each.** This shows the mechanism works and roughly how fast; it is not a
  benchmark.

## Procedure

1. Apply the Terraform (servers, database, failover group, firewall rules). Confirm the
   failover group reports the primary and secondary roles and `Connected`/`Synchronized`.
2. Create the `heartbeat` table (`writer.py init`) and start the writer. Confirm
   `ACK` lines are flowing.
3. Record the replication lag. **Planned failover:** issue it against the secondary
   server, record the command time, wait for it to finish, record the first `ACK`
   after it. Check zero rows lost.
4. Fail back so the roles are the original ones (also a planned failover).
5. Record the replication lag. **Forced failover** (`--allow-data-loss`): record the
   command time, wait for the first `ACK`. Compute RTO, rows lost and RPO.
6. Stop the writer. Save the CSVs under `docs/evidence/`.
7. Publish both results, met or missed, in `docs/sql-drill-001-results.md`.
8. Tear down (below) and verify against Azure directly.

## If it misses

A missed target with a documented cause is worth more than a clean number nobody can
check. Record what was observed and label any explanation as a **hypothesis** unless it
was tested. Do not adjust the targets afterwards.

## Teardown

1. Delete the failover group.
2. Remove the remaining geo-replication link, because the secondary database is created
   by the failover group and is not in Terraform state.
3. `terraform destroy` for the servers, primary database and firewall rules.
4. Verify by direct requests that both servers are gone. Keep the two empty resource
   groups and the $10 budget.
