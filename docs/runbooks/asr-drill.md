# Runbook: ASR failover drill (West US to Central US)

## Objective

Fail the web VM over from West US to Central US with Azure Site Recovery and
measure the real recovery time (RTO) and real data loss (RPO) — not claimed
numbers. A non-disruptive test failover runs first, as it would in practice,
before the real failover.

## Targets — committed BEFORE the drill runs

These were written down and pushed before any failover was triggered, so the
git commit timestamp is the evidence they weren't chosen after seeing results.

- **Target RTO: 15 minutes.** From the moment the failover is triggered to the
  moment the recovery condition below is met.
- **Target RPO: 5 minutes.** The maximum acceptable window of lost writes.

For context, the replication health showed a current RPO of 97 seconds once
the VM reached Protected, so a 5-minute RPO target is a real bar but not a
stretch; the RTO target is the one with genuine uncertainty (the failover job
plus the VM's boot are both in that window).

## Definitions

- **Start event (RTO):** the timestamp the failover is triggered, recorded
  from the terminal and cross-checked against the job's start time in the
  vault's Site Recovery jobs.
- **Recovery condition:** the failed-over VM in Central US is running and
  answers 3 consecutive health checks in a row (each check reads the VM's
  heartbeat file and requires its timestamp to have advanced since the last).
  One lucky success during a flapping start doesn't count.
- **Measured RPO:** a heartbeat process on the source VM writes a UTC
  timestamp to disk every second. Immediately before triggering the real
  failover, the source VM is stopped to simulate an outage, and that stop
  time is recorded. After failover, the newest heartbeat timestamp on the
  recovered VM is read. **RPO = stop time minus newest recovered heartbeat**
  — the writes that never made it across.

## Procedure

1. Confirm the replicated item is **Protected** with health Normal, and note
   the reported RPO.
2. Start the heartbeat on the source VM and confirm it's writing.
3. **Test failover** (non-disruptive, into an isolated test network): confirm
   the VM comes up in Central US, read its heartbeat, then **clean up** the
   test failover. It must be cleaned up before a real failover can run, and
   the region's 4-vCPU quota only has room for one recovered VM at a time.
4. Record the target RTO/RPO again (unchanged). Trigger the real failover with
   the "Latest" recovery point (lowest data loss), after stopping the source
   VM and recording that time.
5. Poll the recovered VM until the recovery condition is met; record the time.
6. Read the recovered VM's newest heartbeat to compute the RPO.
7. Publish both numbers as measured, met or missed, in
   `docs/asr-drill-001-results.md`.

## If it misses

A missed target with a documented cause (recovery point processing time, VM
boot time, agent start, quota or region capacity) is more useful than a clean
number nobody can explain. It gets published the same way, with the cause and
the next change to test.

## After the drill

Disable replication and destroy the stack, then verify against Azure directly
(not just the command's exit code) that both resource groups are empty and the
vault is gone. The drill's evidence — timestamps, job history, results — lives
in this repo; the resources do not need to.

## Notes from drill 001 (added after the run; the targets above are unchanged)

- **The recovered VM is not named like the source.** A real failover named it
  after the replication item (`replication-drdrill-web`); the test failover
  named its VM `<source>-test`. The monitor script polled a guessed name, so
  the "3 consecutive external health checks" condition never ran. Look the
  VM up from the vault instead of assuming a name.
- **Set source shutdown to `Required` on the real failover** (the portal's
  "shut down machine before beginning failover" box). Drill 001 left it
  `NotRequired`, the job skipped "Synchronizing the latest changes", and the
  recovered data was as old as the newest recovery point (5 minutes) rather
  than the replication stream (about 2 minutes). Untested hypothesis; see
  `docs/asr-drill-001-results.md`.
- Recovery points arrive every 5 minutes, so a 5-minute RPO target leaves
  almost no margin unless the latest changes are synchronized first.
