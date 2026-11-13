-- =====================================================================
-- SQL test suite: integrity rules + role-based access control.
-- Run:  psql -d mhportal -v ON_ERROR_STOP=1 -f tests/test_integrity_rbac.sql
-- Everything runs in a transaction that is ROLLED BACK (database unchanged).
-- Needs a superuser (it uses SET ROLE). Any failed check aborts with FAIL.
-- =====================================================================
\set QUIET on
BEGIN;
SET search_path = portal, public;

CREATE FUNCTION public.t_fail(label text, stmt text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE failed boolean := false;
BEGIN
  BEGIN EXECUTE stmt; EXCEPTION WHEN OTHERS THEN failed := true; END;
  IF failed THEN RAISE NOTICE 'PASS  %', label; ELSE RAISE EXCEPTION 'FAIL  % (statement succeeded but should have failed)', label; END IF;
END $$;

CREATE FUNCTION public.t_eq(label text, stmt text, expected bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE got bigint;
BEGIN
  EXECUTE stmt INTO got;
  IF got = expected THEN RAISE NOTICE 'PASS  %', label; ELSE RAISE EXCEPTION 'FAIL  % (expected %, got %)', label, expected, got; END IF;
END $$;

\echo '--- A. Data integrity ---'
SELECT t_fail('duplicate email rejected',
  $$INSERT INTO app_user(email,password_hash,role,full_name) VALUES ('riya@mhportal.test','x','patient','Dup')$$);
SELECT t_fail('malformed email rejected',
  $$INSERT INTO app_user(email,password_hash,role,full_name) VALUES ('not-an-email','x','patient','Bad')$$);
SELECT t_fail('slot with end before start rejected',
  $$INSERT INTO availability_slot(therapist_id,start_time,end_time) VALUES (2, now()+interval '40 days', now()+interval '39 days')$$);
SELECT t_fail('overlapping slots for same therapist rejected',
  $$INSERT INTO availability_slot(therapist_id,start_time,end_time)
    SELECT therapist_id, start_time + interval '30 minutes', end_time + interval '30 minutes'
    FROM availability_slot WHERE start_time > now() ORDER BY slot_id LIMIT 1$$);
SELECT t_fail('booking an already-booked slot rejected',
  $$SELECT book_appointment(6, (SELECT slot_id FROM appointment WHERE status='scheduled' ORDER BY appointment_id LIMIT 1))$$);
SELECT t_fail('booking a slot in the past rejected',
  $$SELECT book_appointment(6, (SELECT slot_id FROM availability_slot WHERE start_time < now() ORDER BY slot_id LIMIT 1))$$);
-- patient 5 already has a session with therapist 2 at time T; another therapist at the same time T must be refused
SELECT t_fail('patient cannot hold two overlapping appointments',
  $$SELECT book_appointment(5, (SELECT s.slot_id FROM availability_slot s
        JOIN appointment a ON a.start_time = s.start_time AND a.patient_id = 5 AND a.status='scheduled'
        WHERE s.therapist_id <> a.therapist_id ORDER BY s.slot_id LIMIT 1))$$);

\echo '--- B. Business rules ---'
INSERT INTO availability_slot(therapist_id,start_time,end_time) VALUES (4, now()+interval '5 hours', now()+interval '6 hours');
SELECT book_appointment(7, (SELECT max(slot_id) FROM availability_slot WHERE therapist_id=4), 'soon');
SELECT t_fail('cancelling inside the 24h window rejected',
  $$SELECT cancel_appointment((SELECT max(appointment_id) FROM appointment WHERE patient_id=7), 7)$$);
SELECT t_fail('cannot cancel another patient''s appointment',
  $$SELECT cancel_appointment((SELECT min(appointment_id) FROM appointment WHERE patient_id=5 AND status='scheduled'), 6)$$);
-- a far-future cancel works and frees the slot for rebooking
SELECT cancel_appointment((SELECT min(appointment_id) FROM appointment WHERE patient_id=6 AND status='scheduled'), 6);
SELECT t_eq('cancelled slot becomes bookable again',
  $$SELECT count(*) FROM v_open_slots WHERE slot_id = (SELECT slot_id FROM appointment WHERE patient_id=6 AND status='cancelled' LIMIT 1)$$, 1);
SELECT t_fail('therapist cannot write a note on another therapist''s appointment',
  $$INSERT INTO session_note(appointment_id,therapist_id,note_text)
    SELECT appointment_id, 4, 'x' FROM appointment WHERE therapist_id = 2 LIMIT 1$$);
-- outcome recording
INSERT INTO availability_slot(therapist_id,start_time,end_time) VALUES (4, now()-interval '3 hours', now()-interval '2 hours');
INSERT INTO appointment(patient_id,therapist_id,slot_id,start_time,end_time,reason)
  SELECT 6, 4, slot_id, start_time, end_time, 'past session' FROM availability_slot WHERE therapist_id=4 AND start_time < now() ORDER BY slot_id DESC LIMIT 1;
SELECT t_fail('only the assigned therapist can complete a session',
  $$SELECT complete_appointment(3, (SELECT max(appointment_id) FROM appointment WHERE therapist_id=4), 'completed')$$);
SELECT complete_appointment(4, (SELECT max(appointment_id) FROM appointment WHERE therapist_id=4 AND start_time<now()), 'completed', 'Good progress');
SELECT t_eq('completing a session stores the note',
  $$SELECT count(*) FROM session_note WHERE note_text='Good progress'$$, 1);
SELECT t_fail('cannot complete a session twice',
  $$SELECT complete_appointment(4, (SELECT max(appointment_id) FROM appointment WHERE therapist_id=4 AND start_time<now()), 'completed')$$);

\echo '--- C. Audit trail ---'
SELECT t_eq('every appointment insert is audited',
  $$SELECT (SELECT count(*) FROM audit_log WHERE table_name='appointment' AND action='INSERT') - (SELECT count(*) FROM appointment)$$, 0);

\echo '--- D. Role-based access control ---'
SET ROLE portal_patient; SET app.user_id = '5';
SELECT t_eq('patient sees only own appointments',
  $$SELECT count(*) FROM appointment WHERE patient_id <> 5$$, 0);
SELECT t_fail('patient cannot read session notes', $$SELECT * FROM session_note$$);
SELECT t_fail('patient cannot publish slots',
  $$INSERT INTO availability_slot(therapist_id,start_time,end_time) VALUES (2, now()+interval '50 days', now()+interval '50 days 1 hour')$$);
SELECT t_fail('patient cannot book on behalf of another patient',
  $$SELECT book_appointment(6, (SELECT slot_id FROM v_open_slots LIMIT 1))$$);
SELECT t_fail('patient cannot edit user accounts', $$UPDATE app_user SET role='admin' WHERE user_id=5$$);
SELECT t_eq('patient sees only own profile',
  $$SELECT count(*) FROM patient$$, 1);
RESET ROLE;

SET ROLE portal_therapist; SET app.user_id = '2';
SELECT t_eq('therapist sees only own appointments',
  $$SELECT count(*) FROM appointment WHERE therapist_id <> 2$$, 0);
SELECT t_eq('therapist sees only own notes',
  $$SELECT count(*) FROM session_note WHERE therapist_id <> 2$$, 0);
SELECT t_eq('therapist sees only own patients',
  $$SELECT count(*) FROM patient WHERE patient_id NOT IN (SELECT patient_id FROM appointment WHERE therapist_id=2)$$, 0);
SELECT t_fail('therapist cannot cancel patient bookings via delete', $$DELETE FROM appointment$$);
SELECT t_fail('therapist cannot read audit log', $$SELECT * FROM audit_log$$);
RESET ROLE;

SET ROLE portal_admin;
SELECT t_eq('admin sees appointments of every patient',
  $$SELECT (count(DISTINCT patient_id) >= 3)::int FROM appointment$$, 1);
SELECT t_eq('admin can read the audit log',
  $$SELECT (count(*) > 0)::int FROM audit_log$$, 1);
RESET ROLE;

DROP FUNCTION public.t_fail(text,text);
DROP FUNCTION public.t_eq(text,text,bigint);
ROLLBACK;
\echo 'ALL TESTS PASSED (transaction rolled back).'
