"""Thin Python data-access layer. Every request runs under the caller's DB role,
so PostgreSQL itself (GRANTs + Row Level Security) enforces access control."""
import os
import psycopg2
import psycopg2.extras

DSN = os.getenv("DATABASE_URL", "dbname=mhportal")


def connect():
    return psycopg2.connect(DSN, cursor_factory=psycopg2.extras.RealDictCursor)


def login(conn, email: str, password: str):
    """Verify credentials with pgcrypto's crypt(); returns the user row or None."""
    with conn.cursor() as cur:
        cur.execute(
            """SELECT user_id, role, full_name FROM portal.app_user
               WHERE email = %s AND is_active
                 AND password_hash = crypt(%s, password_hash)""",
            (email, password),
        )
        return cur.fetchone()


def as_user(conn, user):
    """Switch the session to the user's DB role + identity (drives RLS)."""
    role = {"patient": "portal_patient", "therapist": "portal_therapist", "admin": "portal_admin"}[user["role"]]
    with conn.cursor() as cur:
        cur.execute("RESET ROLE")
        cur.execute("SELECT set_config('app.user_id', %s, false)", (str(user["user_id"]),))
        cur.execute(f"SET ROLE {role}")  # role comes from a fixed whitelist above


def open_slots(conn, therapist_id=None):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM portal.v_open_slots WHERE (%s IS NULL OR therapist_id=%s) ORDER BY start_time LIMIT 20",
            (therapist_id, therapist_id))
        return cur.fetchall()


def book(conn, patient_id, slot_id, reason=None):
    with conn.cursor() as cur:
        cur.execute("SELECT portal.book_appointment(%s,%s,%s) AS id", (patient_id, slot_id, reason))
        return cur.fetchone()["id"]


def cancel(conn, appt_id, patient_id):
    with conn.cursor() as cur:
        cur.execute("SELECT portal.cancel_appointment(%s,%s)", (appt_id, patient_id))


def my_appointments(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT appointment_id, therapist_id, patient_id, start_time, status FROM portal.appointment ORDER BY start_time")
        return cur.fetchall()
