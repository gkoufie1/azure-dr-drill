"""Write load and measurement helper for the Azure SQL failover group drill.

  python writer.py init   --host <listener>        create the heartbeat table
  python writer.py write  --host <listener>        insert ~10 rows/s, log every outcome to a CSV
  python writer.py verify --host <listener>        max seq, row count and replication lag

The password is read from .sql-admin-password (gitignored) and never printed.

Every insert is autocommit, so an ACK means the database confirmed that one row.
The CSV is the evidence the drill's numbers are computed from:
    event,seq,utc,detail   where event is ACK, FAIL or RECONNECT

Design note (learned the hard way, see docs/sql-drill-001-results.md): the database
driver's own timeouts do not fire when a failover drops a connection, and a thread
stuck inside the driver can block every later connection in the same process. So
`write` is a small supervisor: the inserts run in a WORKER PROCESS, and if the worker
goes quiet the supervisor kills the whole process, logs a FAIL and starts a new one.
An operating-system kill is the only stop that cannot be ignored.
"""
import argparse
import csv
import os
import queue
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

import pymssql

HERE = os.path.dirname(os.path.abspath(__file__))
DB = "drilldb"
USER = "sqldrilladmin"
CONNECT_DEADLINE = 10.0  # seconds a fresh worker gets to produce its first line
INSERT_DEADLINE = 3.0  # seconds of silence from a connected worker before it is killed


def password():
    with open(os.path.join(HERE, ".sql-admin-password"), encoding="utf-8") as f:
        return f.read().strip()


def connect(host, timeout=5):
    # A fresh connection re-resolves DNS, which is how a client follows the
    # failover group's listener to the new primary.
    return pymssql.connect(
        server=host, user=USER, password=password(), database=DB,
        login_timeout=timeout, timeout=timeout, autocommit=True,
    )


def now():
    return datetime.now(timezone.utc)


def stamp(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def cmd_init(args):
    conn = connect(args.host)
    cur = conn.cursor()
    cur.execute(
        "IF OBJECT_ID('dbo.heartbeat') IS NULL "
        "CREATE TABLE dbo.heartbeat (seq INT NOT NULL PRIMARY KEY, client_utc DATETIME2(3) NOT NULL)"
    )
    print("heartbeat table ready")
    conn.close()


def cmd_verify(args):
    conn = connect(args.host)
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*), MAX(seq), MAX(client_utc) FROM dbo.heartbeat")
    count, max_seq, max_utc = cur.fetchone()
    print(f"rows={count} max_seq={max_seq} max_client_utc={max_utc}")
    try:
        cur.execute(
            "SELECT partner_server, role_desc, replication_state_desc, replication_lag_sec "
            "FROM sys.dm_geo_replication_link_status"
        )
        for row in cur.fetchall():
            print("link: partner=%s role=%s state=%s lag_sec=%s" % row)
    except pymssql.Error as e:
        print("replication link status not available on this connection:", str(e)[:120])
    conn.close()


def cmd_worker(args):
    """One connection, inserting until anything goes wrong. Prints one line per event."""
    seq = args.start
    try:
        conn = connect(args.host)
    except Exception as e:  # noqa: BLE001
        print("FAIL", seq, stamp(now()), str(e).replace("\n", " ")[:160], flush=True)
        return 1
    print("RECONNECT", seq, stamp(now()), "connected", flush=True)
    cur = conn.cursor()
    while True:
        tick = time.monotonic()
        ts = now()
        try:
            cur.execute(
                "INSERT INTO dbo.heartbeat (seq, client_utc) VALUES (%d, %s)",
                (seq, ts.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]),
            )
            print("ACK", seq, stamp(now()), "", flush=True)
            seq += 1
        except pymssql.IntegrityError:
            # The attempt that seemed to fail had actually committed: it is present.
            print("ACK", seq, stamp(now()), "already-present", flush=True)
            seq += 1
        except Exception as e:  # noqa: BLE001
            print("FAIL", seq, stamp(now()), str(e).replace("\n", " ")[:160], flush=True)
            return 1
        time.sleep(max(0.0, args.interval - (time.monotonic() - tick)))


def spawn(args, seq):
    proc = subprocess.Popen(
        [sys.executable, "-u", os.path.abspath(__file__), "_worker",
         "--host", args.host, "--start", str(seq), "--interval", str(args.interval)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
    )
    q = queue.Queue()

    def pump():
        for line in proc.stdout:
            q.put(line.rstrip("\n"))
        q.put(None)  # worker exited

    threading.Thread(target=pump, daemon=True).start()
    return proc, q


def cmd_write(args):
    os.makedirs(args.out_dir, exist_ok=True)
    path = os.path.join(args.out_dir, f"writer-{now().strftime('%Y%m%dT%H%M%SZ')}.csv")
    print("logging to", path)
    print("Ctrl+C to stop")

    if args.start is None:
        c0 = connect(args.host)
        cur0 = c0.cursor()
        cur0.execute("SELECT ISNULL(MAX(seq), 0) FROM dbo.heartbeat")
        args.start = cur0.fetchone()[0] + 1
        c0.close()
    seq = args.start
    print("starting at seq", seq)

    with open(path, "w", newline="", encoding="utf-8") as f:
        log = csv.writer(f)
        log.writerow(["event", "seq", "utc", "detail"])
        f.flush()
        proc, q = spawn(args, seq)
        deadline = CONNECT_DEADLINE
        try:
            while True:
                try:
                    line = q.get(timeout=deadline)
                except queue.Empty:
                    line = "TIMEOUT"
                if line == "TIMEOUT" or line is None or line.startswith("FAIL"):
                    if line == "TIMEOUT":
                        proc.kill()  # cannot be ignored, unlike a driver timeout
                        log.writerow(["FAIL", seq, stamp(now()), f"no response within {deadline:.0f}s (worker killed)"])
                    elif line is None:
                        log.writerow(["FAIL", seq, stamp(now()), "worker exited"])
                    else:
                        _, s, ts, detail = (line.split(" ", 3) + [""])[:4]
                        log.writerow(["FAIL", s, ts, detail])
                    f.flush()
                    try:
                        proc.kill()
                    except Exception:
                        pass
                    time.sleep(0.5)  # do not spin while the database is unreachable
                    proc, q = spawn(args, seq)
                    deadline = CONNECT_DEADLINE
                    continue
                event, s, ts, detail = (line.split(" ", 3) + [""])[:4]
                log.writerow([event, s, ts, detail])
                f.flush()
                if event == "ACK":
                    seq = int(s) + 1
                deadline = INSERT_DEADLINE
        except KeyboardInterrupt:
            print("\nstopped at seq", seq - 1)
        finally:
            try:
                proc.kill()
            except Exception:
                pass


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["init", "write", "verify", "_worker"])
    p.add_argument("--host", required=True, help="failover group listener, <name>.database.windows.net")
    p.add_argument("--interval", type=float, default=0.1, help="seconds between inserts")
    p.add_argument("--start", type=int, default=None, help="first sequence number (default: max in database + 1)")
    p.add_argument("--out-dir", default=os.path.join(HERE, "..", "..", "docs", "evidence"))
    args = p.parse_args()
    return {"init": cmd_init, "write": cmd_write, "verify": cmd_verify, "_worker": cmd_worker}[args.mode](args)


if __name__ == "__main__":
    sys.exit(main())
