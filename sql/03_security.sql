-- =====================================================================
-- 03_security.sql : role-based access control (GRANT + Row Level Security)
-- The application runs:  SET app.user_id = '<id>';  SET ROLE portal_<role>;
-- =====================================================================
SET search_path = portal, public;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='portal_admin')     THEN CREATE ROLE portal_admin;     END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='portal_therapist') THEN CREATE ROLE portal_therapist; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='portal_patient')   THEN CREATE ROLE portal_patient;   END IF;
END $$;

GRANT USAGE ON SCHEMA portal TO portal_admin, portal_therapist, portal_patient;

-- Admin: full control
GRANT ALL ON ALL TABLES    IN SCHEMA portal TO portal_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA portal TO portal_admin;

-- Patient: browse therapists/slots, manage only own appointments
GRANT SELECT ON specialization, therapist_specialization, therapist, availability_slot, v_open_slots TO portal_patient;
GRANT SELECT ON app_user TO portal_patient;
GRANT SELECT, UPDATE ON patient TO portal_patient;
GRANT SELECT, INSERT, UPDATE ON appointment TO portal_patient;
GRANT USAGE ON SEQUENCE appointment_appointment_id_seq TO portal_patient;
GRANT INSERT ON audit_log TO portal_patient, portal_therapist;
GRANT USAGE ON SEQUENCE audit_log_log_id_seq TO portal_patient, portal_therapist;

-- Therapist: manage own slots, see own appointments, write own notes
GRANT SELECT ON specialization, therapist_specialization, therapist, app_user, patient TO portal_therapist;
GRANT SELECT, INSERT, UPDATE, DELETE ON availability_slot TO portal_therapist;
GRANT USAGE ON SEQUENCE availability_slot_slot_id_seq TO portal_therapist;
GRANT SELECT, UPDATE ON appointment TO portal_therapist;
GRANT SELECT, INSERT, UPDATE ON session_note TO portal_therapist;
GRANT USAGE ON SEQUENCE session_note_note_id_seq TO portal_therapist;

-- Helper: current application user
CREATE OR REPLACE FUNCTION current_app_user() RETURNS INT
LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.user_id', true), '')::INT $$;
GRANT EXECUTE ON FUNCTION current_app_user() TO portal_admin, portal_therapist, portal_patient;

-- ---------- Row Level Security ----------
ALTER TABLE appointment   ENABLE ROW LEVEL SECURITY;
ALTER TABLE session_note  ENABLE ROW LEVEL SECURITY;
ALTER TABLE patient       ENABLE ROW LEVEL SECURITY;

CREATE POLICY admin_all_appt ON appointment FOR ALL TO portal_admin USING (true) WITH CHECK (true);
CREATE POLICY admin_all_note ON session_note FOR ALL TO portal_admin USING (true) WITH CHECK (true);
CREATE POLICY admin_all_pat  ON patient FOR ALL TO portal_admin USING (true) WITH CHECK (true);

-- Patients: own rows only
CREATE POLICY patient_own_appt ON appointment TO portal_patient
    USING (patient_id = current_app_user()) WITH CHECK (patient_id = current_app_user());
CREATE POLICY patient_own_row ON patient TO portal_patient
    USING (patient_id = current_app_user()) WITH CHECK (patient_id = current_app_user());

-- Therapists: their own appointments; profiles of their own patients only
CREATE POLICY therapist_own_appt ON appointment TO portal_therapist
    USING (therapist_id = current_app_user()) WITH CHECK (therapist_id = current_app_user());
CREATE POLICY therapist_own_patients ON patient TO portal_therapist
    USING (EXISTS (SELECT 1 FROM appointment a
                   WHERE a.patient_id = patient.patient_id
                     AND a.therapist_id = current_app_user()));

-- Session notes: authoring therapist only (patients have NO policy => zero access)
CREATE POLICY therapist_own_notes ON session_note TO portal_therapist
    USING (therapist_id = current_app_user()) WITH CHECK (therapist_id = current_app_user());

-- Booking / cancel / audit run with definer rights so validation can see all slots
ALTER FUNCTION book_appointment(INT,INT,TEXT) SECURITY DEFINER SET search_path = portal, public;
ALTER FUNCTION cancel_appointment(INT,INT)    SECURITY DEFINER SET search_path = portal, public;
ALTER FUNCTION trg_audit()                    SECURITY DEFINER SET search_path = portal, public;
ALTER FUNCTION trg_appt_match_slot()          SECURITY DEFINER SET search_path = portal, public;
ALTER FUNCTION trg_note_owner()               SECURITY DEFINER SET search_path = portal, public;
GRANT EXECUTE ON FUNCTION book_appointment(INT,INT,TEXT), cancel_appointment(INT,INT) TO portal_patient;
GRANT SELECT ON v_appointment_details TO portal_admin;

ALTER FUNCTION complete_appointment(INT,INT,appt_status,TEXT) SECURITY DEFINER SET search_path = portal, public;
GRANT EXECUTE ON FUNCTION complete_appointment(INT,INT,appt_status,TEXT) TO portal_therapist;
