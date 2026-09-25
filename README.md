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

**Status:** in progress. Nothing is deployed yet — this commit is the
scaffold and its first plan (21 resources, not yet applied).

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

## Layout

```
terraform/asr-lab/     VNets, one VM, Recovery Services vault, ASR replication
```

## Cost guardrails

A $10/month Azure budget alerts at 50/80/100%, and the trial's spending limit
means the subscription can't run up a real bill. Every session ends with
teardown, verified independently rather than trusting an exit code.
