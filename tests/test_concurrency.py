"""Proves the booking logic is race-free: N patients try to grab the SAME slot
at the same instant -> exactly one succeeds, the rest get 'already booked'.
Run:  DATABASE_URL="dbname=mhportal" python tests/test_concurrency.py"""
import os, sys, threading
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from app import db

N = 12


def main():
    admin = db.connect(); admin.autocommit = True
    cur = admin.cursor()
    # create N throw-away patients
    cur.execute("SELECT max(user_id) AS m FROM portal.app_user"); base = cur.fetchone()["m"]
    ids = []
    for i in range(N):
        cur.execute("""INSERT INTO portal.app_user(email,password_hash,role,full_name)
                       VALUES (%s,'x','patient',%s) RETURNING user_id""", (f"race{base}_{i}@t.test", f"Racer {i}"))
        uid = cur.fetchone()["user_id"]; ids.append(uid)
        cur.execute("INSERT INTO portal.patient(patient_id,date_of_birth) VALUES (%s,'2000-01-01')", (uid,))
    cur.execute("""INSERT INTO portal.availability_slot(therapist_id,start_time,end_time)
                   VALUES (4, now()+interval '30 days', now()+interval '30 days 1 hour') RETURNING slot_id""")
    slot = cur.fetchone()["slot_id"]

    results, barrier = [], threading.Barrier(N)

    def worker(pid):
        c = db.connect()
        try:
            barrier.wait()
            db.book(c, pid, slot, "race"); c.commit(); results.append("OK")
        except Exception as e:
            c.rollback(); results.append("FAIL: " + str(e).splitlines()[0])
        finally:
            c.close()

    ts = [threading.Thread(target=worker, args=(p,)) for p in ids]
    [t.start() for t in ts]; [t.join() for t in ts]

    wins = results.count("OK")
    print(f"{N} concurrent attempts -> {wins} success, {N-wins} rejected")
    print(sorted(set(r for r in results if r != 'OK')))
    cur.execute("SELECT count(*) AS c FROM portal.appointment WHERE slot_id=%s AND status='scheduled'", (slot,))
    assert cur.fetchone()["c"] == 1 and wins == 1, "DOUBLE BOOKING DETECTED"
    print("PASS: no double booking")


if __name__ == "__main__":
    main()
