"""Interactive CLI demo:  python -m app.cli"""
import getpass
from . import db


def main():
    conn = db.connect()
    conn.autocommit = False
    email = input("Email: ").strip()
    user = db.login(conn, email, getpass.getpass("Password: "))
    if not user:
        print("Invalid credentials"); return
    db.as_user(conn, user)
    print(f"\nWelcome {user['full_name']} ({user['role']})")
    while True:
        print("\n1) Open slots  2) My appointments  3) Book (patients)  4) Cancel (patients)  0) Exit")
        c = input("> ").strip()
        try:
            if c == "1":
                for s in db.open_slots(conn): print(s["slot_id"], s["therapist_name"], s["start_time"], s["session_fee"])
            elif c == "2":
                for a in db.my_appointments(conn): print(a)
            elif c == "3":
                print("Booked appointment", db.book(conn, user["user_id"], int(input("Slot id: ")), input("Reason: ")))
            elif c == "4":
                db.cancel(conn, int(input("Appointment id: ")), user["user_id"]); print("Cancelled")
            elif c == "0":
                break
            conn.commit()
        except Exception as e:  # show DB-level business-rule errors cleanly
            conn.rollback(); db.as_user(conn, user)
            print("Error:", str(e).splitlines()[0])


if __name__ == "__main__":
    main()
