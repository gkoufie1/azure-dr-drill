# ASR drill 001 — results

**Date:** 2026-09-25 · **Path:** West US → Central US · **Workload:** one Ubuntu 24.04 VM
(`Standard_D2als_v7`) with a heartbeat writing a UTC timestamp to disk every second.

Targets were committed to the repo **before** the run ([`64dfe3d`](https://github.com/gkoufie1/azure-dr-drill/commit/64dfe3d)):
RTO 15 minutes, RPO 5 minutes.

## Verdict

| | Target | Measured | Result |
|---|---|---|---|
| **RTO** | 15 min | **2 min 34 s** (153.7 s) | **Met**, with a caveat about how it was measured (below) |
| **RPO** | 5 min | **304 s (5 min 4 s)** of lost writes | **Missed**, by 4 seconds at minimum |

## Timeline (UTC)

| Time | Event |
|---|---|
| 22:29:09.465 | Last heartbeat that reached the recovered VM. It matches the 22:29:10 recovery point. |
| 22:34:13.424 | **Outage simulated:** `az vm deallocate` issued on the source VM (`T_stop`) |
| 22:34:46.559 | Deallocation complete (33 s later) |
| 22:34:46.643 | **Failover triggered** (`T0`), recovery point type "Latest" |
| 22:34:51.118 | ASR job started |
| 22:35:12 – 22:35:14 | Prerequisites check (1.6 s) |
| 22:35:14 – 22:37:30 | Start failover (2 min 16 s) |
| 22:37:06 | Recovered VM's guest clock: booted |
| **22:37:20.343** | **First fresh heartbeat on the recovered VM: the workload is running** |
| 22:37:30 – 22:37:31 | Start the replica VM (1 s). Job Succeeded, portal duration 2:38 |

## How the numbers were derived

- **RTO = 153.7 s:** first fresh heartbeat on the recovered VM (22:37:20.343) minus the
  failover trigger (22:34:46.643). Measured from the recovered VM's own log, not from an
  external poll. Measured from the moment the outage began (22:34:13.424) rather than the
  trigger, it is 186.9 s (3 min 7 s).
- **RPO = 304.0 s:** `T_stop` minus the last heartbeat found on the recovered VM
  (22:34:13.424 − 22:29:09.465). The heartbeat file has one large gap of 490.9 s, which
  splits exactly into 304.0 s of writes that never arrived plus 186.9 s from outage to
  workload running. Against the moment the deallocation *finished* instead, it would be 337 s.

## Caveats — read these before quoting the numbers

1. **The RTO was not measured the way the runbook defined it.** The recovery condition was
   "3 consecutive external health checks". My monitoring script polled for a VM named
   `vm-drdrill-web`; ASR actually named the recovered VM `replication-drdrill-web`, after the
   replication item. So the checks never ran (40 "no answer yet"), and the recovered VM ran
   unobserved until I looked. The 153.7 s is what the VM's own log shows. Judging by the test
   failover, where the first external check passed about 30 s after the first heartbeat, the
   runbook-definition RTO would be roughly 3.5 to 4 minutes. That is an estimate, not a
   measurement, and it is still well inside 15 minutes.
2. **The RPO is a lower bound.** The source guest kept running for some seconds after the
   stop command while it shut down, so the source's true last write was a little later than
   `T_stop`, and the real loss is slightly *more* than 304 s, never less. It misses either way.
3. **One run.** One VM, crash-consistent recovery points, a synthetic write pattern, a lab
   network. It shows that the mechanism works and roughly how fast; it is not a benchmark.

## Why the RPO missed (hypothesis — not tested)

ASR reported a current RPO of about 2 minutes just before the stop (137 s at pre-flight), yet the
recovered data was 5 minutes old, the age of the newest *recovery point* rather than of the
replication stream. The job's step list shows **"Shut down the virtual machine" and
"Synchronizing the latest changes" did not run.** I set `sourceSiteOperations` to
`NotRequired`, which corresponds to leaving the portal's "shut down machine before beginning
failover" box unchecked. That appears to skip the step that would process the data already sent
to ASR and produce a fresher point, so "Latest" behaved like "latest existing recovery point".
Recovery points are taken every 5 minutes, and the next one after 22:29:10 was due at about
22:34:10, three seconds *before* I stopped the VM; the failover used the 22:29:10 point, so
whether a 22:34:10 point existed by then I can't say. To test the hypothesis, re-run with the
option set to `Required`.

## What went wrong on my side

- **Wrong VM name in the monitor script,** described above. Root cause: I assumed the real
  failover would name the VM like the test failover did (`<source>-test`) or like the source.
  The recovered VM should be looked up from the vault, not guessed.
- **The screenshot instructions gave the same wrong name** and had to be corrected mid-drill.

## Test failover (the rehearsal) — a separate baseline, not the drill's RPO

| | Value |
|---|---|
| Job duration (portal) | 2 min 38 s |
| Trigger to first fresh heartbeat | 157.0 s |
| Recovery point used | 21:54:09, chosen explicitly |
| Heartbeat gap | 533.5 s = 376.4 s of data older than that recovery point + 157.0 s of failover |
| Cleanup job | 1 min 09 s; the test VM, NIC and disk were confirmed gone against Azure |

The test used an explicit, older recovery point, so its data-loss window says nothing
about the drill's RPO. It also would have exceeded 5 minutes, which is how it flagged
the recovery-point issue that the real run then hit at a smaller scale.

## Evidence

| Screenshot | Shows |
|---|---|
| `screenshots/replicated-item-protected-healthy.png` | The replicated item Protected, Healthy, active location West US |
| `screenshots/replicated-item-failover-readiness.png` | RPO 2 min, last successful test failover, agent build **9.67.7789.1**, no issues |
| `screenshots/site-recovery-jobs-through-test-failover.png` | All three enable-replication attempts (failed, failed, succeeded), test failover 2:38, cleanup 1:09 |
| `screenshots/test-failover-recovered-vm.png` | The test-failover VM, running in Central US |
| `screenshots/resource-group-centralus-after-test-cleanup.png` | Recovery group after cleanup: NSG, VNet, vault and the replica disk |
| `screenshots/source-vm-deallocated.png` | The source VM Stopped (deallocated): the simulated outage |
| `screenshots/site-recovery-jobs-real-failover-succeeded.png` | The real Failover job, Succeeded, 2:38 |
| `screenshots/real-failover-recovered-vm.png` | `replication-drdrill-web` running in Central US, computer name `vm-drdrill-web` |

## Next

- Re-run with source shutdown set to `Required` to test the RPO hypothesis, and find the
  recovered VM by querying the vault.
- Give the recovery side an explicit outbound path (the portal flags the recovered VM's
  default outbound IP; the source VM has one, the recovery side does not).
- Azure SQL failover group drill, which measures RTO and RPO again on a managed service.
