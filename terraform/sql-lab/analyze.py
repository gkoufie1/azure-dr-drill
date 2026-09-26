"""Compute the drill's numbers from the writer's CSV and the database.

  python analyze.py --csv <writer.csv> --host <listener> --issued 2026-09-26T17:07:43.787Z [--until <utc>]

Reads every acknowledged sequence number from the CSV, reads every sequence number that
exists in the database (through the listener, i.e. the current primary), and reports:
  - the outage window as the client saw it (first FAIL to first ACK after the last FAIL)
  - RTO: failover command issued -> first ACK after the outage
  - acknowledged rows missing from the database (rows lost), and the RPO window
"""
import argparse
import csv
import os
import sys
from datetime import datetime, timezone

import pymssql

HERE = os.path.dirname(os.path.abspath(__file__))


def parse(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--csv", required=True)
    p.add_argument("--host", required=True)
    p.add_argument("--issued", required=True, help="UTC time the failover command was issued")
    p.add_argument("--until", help="ignore log events after this UTC time (use when the log holds a later failover too)")
    a = p.parse_args()
    issued = parse(a.issued)
    until = parse(a.until) if a.until else None

    acks, fails = {}, []
    with open(a.csv, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            t = parse(r["utc"])
            if until and t > until:
                continue
            if r["event"] == "ACK":
                acks[int(r["seq"])] = t
            elif r["event"] == "FAIL":
                fails.append((t, r["detail"]))

    with open(os.path.join(HERE, ".sql-admin-password"), encoding="utf-8") as f:
        pw = f.read().strip()
    conn = pymssql.connect(server=a.host, user="sqldrilladmin", password=pw, database="drilldb",
                           login_timeout=10, timeout=60)
    cur = conn.cursor()
    cur.execute("SELECT seq, client_utc FROM dbo.heartbeat")
    present = {int(s): u for s, u in cur.fetchall()}
    conn.close()

    print(f"acknowledged rows in CSV : {len(acks)}")
    print(f"rows present in database : {len(present)}")
    missing = sorted(set(acks) - set(present))
    print(f"acked but MISSING (lost) : {len(missing)}" + (f"  seq {missing[0]}..{missing[-1]}" if missing else ""))

    after = [(t, d) for t, d in fails if t >= issued]
    print(f"FAIL events after issue  : {len(after)}   (total FAILs in file: {len(fails)})")
    if after:
        first_fail, last_fail = after[0][0], after[-1][0]
        acks_before = [t for t in acks.values() if t < first_fail]
        acks_after = [t for t in acks.values() if t > last_fail]
        last_ok_before = max(acks_before)
        first_ok_after = min(acks_after)
        print(f"last ACK before outage   : {last_ok_before.isoformat()}")
        print(f"first FAIL               : {first_fail.isoformat()}  ({(first_fail - issued).total_seconds():.1f}s after issue)")
        print(f"last FAIL                : {last_fail.isoformat()}")
        print(f"first ACK after outage   : {first_ok_after.isoformat()}")
        print(f"OUTAGE WINDOW (client)   : {(first_ok_after - last_ok_before).total_seconds():.2f} s")
        print(f"RTO (issue -> first ACK) : {(first_ok_after - issued).total_seconds():.2f} s")
        print("first error text         :", after[0][1])
    else:
        print("no FAIL after issue: the writer never saw an error")

    if missing:
        last_acked = max(acks)
        surviving = [s for s in acks if s in present]
        newest_surviving_before_gap = max(s for s in surviving if s < missing[0])
        rpo = (acks[missing[-1]] - acks[newest_surviving_before_gap]).total_seconds()
        print(f"RPO window (acked but lost, client clock): about {rpo:.2f} s")


if __name__ == "__main__":
    sys.exit(main())
