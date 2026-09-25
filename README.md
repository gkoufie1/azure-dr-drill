# azure-dr-drill

Two measured disaster-recovery drills on Azure, built the same way as the
AWS drill in [`eks-gitops-dr-drill`](https://github.com/gkoufie1/eks-gitops-dr-drill):
targets set before the drill, real failovers under real conditions, results
published as measured, teardown verified against the cloud directly.

1. **Azure Site Recovery (ASR)** — replicate a small VM tier from West US to
   Central US, run a non-disruptive test failover, then a real failover, and
   measure RTO and RPO.
2. **Azure SQL failover group** — force a failover under live traffic and
   measure both RTO *and* RPO (the AWS drill measured RTO only).

**Status:** in progress. The ASR canary is deployed and replicating (health
Normal, initial replication in progress at the time of writing) after three
attempts, each of which failed for a different documented reason — see below.
The failover drills themselves have **not** run yet, so there are no RTO/RPO
numbers in this repo yet, and none are claimed.

## Constraints found on the way (all checked against the live subscription)

This runs on an Azure **Free Trial** subscription (spending limit on, 4 vCPU
quota per region), which shaped the design before a single resource existed:

- **Older VM sizes are unavailable.** B1s, B2s, D2s_v3, DS1_v2 and similar
  return `NotAvailableForSubscription` in East US, West US, East US 2 and
  Central US. (An earlier read of mine said *every* size was blocked — that was
  wrong; only the older generations are. Newer v6/v7 series are open.)
- **Azure SQL is region-restricted.** Provisioning is blocked in East US,
  East US 2, North Central, South Central and West US 2. It is available in
  West US, West US 3 and Central US.
- **So the region pair is West US ↔ Central US** — the only combination where
  both a usable VM size and Azure SQL exist. It is *not* a Microsoft-paired
  combination (West US pairs with East US; Central US pairs with East US 2),
  so this repo calls it a geo-separated pair, not a paired one.
- **Recovery Services vault soft delete can't be turned off.** An earlier draft
  tried to disable it to simplify teardown; the provider rejects that as a
  required security feature. Corrected in `asr.tf`.

## Three attempts to enable ASR replication (what actually broke)

A one-VM canary existed to answer "will ASR accept this VM?" before building
the full lab. It took three tries, and each error was different:

1. **Error 151273 — NVMe + Ubuntu 22.04.** The v7 VM sizes use an NVMe disk
   controller, and ASR only supports NVMe with certain guest operating
   systems: RHEL 9.0-9.7, Ubuntu 24.04 LTS, SLES 15 SP4-SP7 (Microsoft's ASR
   support matrix). Fixed by moving to Ubuntu 24.04. (A fallback to a SCSI
   disk controller was considered and ruled out: `Standard_D2als_v7` reports
   `DiskControllerTypes = NVMe` only.)
2. **Error 151141 — kernel not supported by the agent.** With 24.04, the OS
   check passed, but ASR rejected the running kernel, `6.17.0-1022-azure`.
   Kernel support is tracked per Mobility-agent build in the
   `Azure/Azure-SiteRecovery` GitHub repo. The build this vault installed
   (9.67.7789.1, published 2026-05-04) tops out at `6.14.0-1017-azure` for
   Ubuntu 24.04; the first build that lists 6.17.0-1022 is 7893 (2026-08-13).
   An older marketplace image did **not** help — the April 2026 image already
   ran 6.17 — so the fix was installing the supported 6.14.0-1017 kernel,
   making GRUB boot it, and turning off automatic updates. (`pinned_kernel`
   in `variables.tf`; cloud-init in `compute.tf`.)
3. **A leftover failed record.** The second attempt got far enough to create
   a replication record in `EnablingFailed` state, which made the third
   `terraform apply` fail with "already exists — needs to be imported."
   Removed with ASR's disable-replication call, then applied cleanly.

The failed jobs remain visible in the vault's Site Recovery jobs history.

## Layout

```
terraform/asr-lab/     VNets, one VM, Recovery Services vault, ASR replication
```

## Cost guardrails

A $10/month Azure budget alerts at 50/80/100%, and the trial's spending limit
means the subscription can't run up a real bill. Every session ends with
teardown, verified independently rather than trusting an exit code.
