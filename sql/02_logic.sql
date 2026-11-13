-- =====================================================================
-- 02_logic.sql : stored functions, triggers, views
-- =====================================================================
SET search_path = portal, public;

-- ---------- Concurrency-safe booking ----------
-- Locks the slot row (SELECT ... FOR UPDATE) so two sessions booking the
-- same slot are serialised: the second one waits, then sees it is taken.
CREATE OR REPLACE FUNCTION book_appointment(p_patient INT, p_slot INT, p_reason TEXT DEFAULT NULL)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    v_slot availability_slot%ROWTYPE;
    v_id   INT;
BEGIN
    IF current_app_user() IS NOT NULL AND current_app_user() <> p_patient THEN
        RAISE EXCEPTION 'You can only act on your own behalf' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO v_slot FROM availability_slot WHERE slot_id = p_slot FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Slot % does not exist', p_slot USING ERRCODE = 'P0002';
    END IF;
    IF v_slot.start_time <= now() THEN
        RAISE EXCEPTION 'Cannot book a slot in the past' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM appointment WHERE slot_id = p_slot AND status = 'scheduled') THEN
        RAISE EXCEPTION 'Slot % is already booked', p_slot USING ERRCODE = 'P0003';
    END IF;

    INSERT INTO appointment(patient_id, therapist_id, slot_id, start_time, end_time, reason)
    VALUES (p_patient, v_slot.therapist_id, p_slot, v_slot.start_time, v_slot.end_time, p_reason)
    RETURNING appointment_id INTO v_id;
    RETURN v_id;
END $$;

-- ---------- Cancellation policy: >= 24h before start ----------
CREATE OR REPLACE FUNCTION cancel_appointment(p_appt INT, p_patient INT)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE v_appt appointment%ROWTYPE;
BEGIN
    IF current_app_user() IS NOT NULL AND current_app_user() <> p_patient THEN
        RAISE EXCEPTION 'You can only act on your own behalf' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO v_appt FROM appointment WHERE appointment_id = p_appt FOR UPDATE;
    IF NOT FOUND OR v_appt.patient_id <> p_patient THEN
        RAISE EXCEPTION 'Appointment not found for this patient' USING ERRCODE = 'P0002';
    END IF;
    IF v_appt.status <> 'scheduled' THEN
        RAISE EXCEPTION 'Only scheduled appointments can be cancelled' USING ERRCODE = 'P0001';
    END IF;
    IF v_appt.start_time - now() < INTERVAL '24 hours' THEN
        RAISE EXCEPTION 'Cancellation window closed (< 24h before session)' USING ERRCODE = 'P0001';
    END IF;
    UPDATE appointment SET status = 'cancelled', cancelled_at = now() WHERE appointment_id = p_appt;
END $$;

-- ---------- Keep appointment consistent with its slot ----------
CREATE OR REPLACE FUNCTION trg_appt_match_slot() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s availability_slot%ROWTYPE;
BEGIN
    SELECT * INTO s FROM availability_slot WHERE slot_id = NEW.slot_id;
    IF s.therapist_id <> NEW.therapist_id
       OR s.start_time <> NEW.start_time OR s.end_time <> NEW.end_time THEN
        RAISE EXCEPTION 'Appointment does not match its slot';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER appt_match_slot BEFORE INSERT ON appointment
    FOR EACH ROW EXECUTE FUNCTION trg_appt_match_slot();

-- ---------- Only the appointment's therapist may write its note ----------
CREATE OR REPLACE FUNCTION trg_note_owner() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM appointment
                   WHERE appointment_id = NEW.appointment_id
                     AND therapist_id = NEW.therapist_id) THEN
        RAISE EXCEPTION 'Therapist % is not assigned to appointment %',
                        NEW.therapist_id, NEW.appointment_id;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER note_owner BEFORE INSERT OR UPDATE ON session_note
    FOR EACH ROW EXECUTE FUNCTION trg_note_owner();

-- ---------- Generic audit trigger ----------
CREATE OR REPLACE FUNCTION trg_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log(table_name, action, row_id, new_data)
        VALUES (TG_TABLE_NAME, TG_OP, (to_jsonb(NEW)->>TG_ARGV[0])::INT, to_jsonb(NEW));
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_log(table_name, action, row_id, old_data, new_data)
        VALUES (TG_TABLE_NAME, TG_OP, (to_jsonb(NEW)->>TG_ARGV[0])::INT, to_jsonb(OLD), to_jsonb(NEW));
    ELSE
        INSERT INTO audit_log(table_name, action, row_id, old_data)
        VALUES (TG_TABLE_NAME, TG_OP, (to_jsonb(OLD)->>TG_ARGV[0])::INT, to_jsonb(OLD));
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER audit_appointment AFTER INSERT OR UPDATE OR DELETE ON appointment
    FOR EACH ROW EXECUTE FUNCTION trg_audit('appointment_id');

-- ---------- Views ----------
CREATE OR REPLACE VIEW v_open_slots AS
SELECT s.slot_id, s.therapist_id, u.full_name AS therapist_name,
       s.start_time, s.end_time, t.session_fee
FROM availability_slot s
JOIN therapist t ON t.therapist_id = s.therapist_id
JOIN app_user  u ON u.user_id      = s.therapist_id
WHERE s.start_time > now()
  AND NOT EXISTS (SELECT 1 FROM appointment a
                  WHERE a.slot_id = s.slot_id AND a.status = 'scheduled');

CREATE OR REPLACE VIEW v_appointment_details AS
SELECT a.appointment_id, a.status, a.start_time, a.end_time, a.reason,
       a.patient_id,   pu.full_name AS patient_name,
       a.therapist_id, tu.full_name AS therapist_name
FROM appointment a
JOIN app_user pu ON pu.user_id = a.patient_id
JOIN app_user tu ON tu.user_id = a.therapist_id;

-- ---------- Therapist records the outcome of a finished session ----------
CREATE OR REPLACE FUNCTION complete_appointment(p_therapist INT, p_appt INT,
                                                p_outcome appt_status, p_note TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE v_appt appointment%ROWTYPE;
BEGIN
    IF current_app_user() IS NOT NULL AND current_app_user() <> p_therapist THEN
        RAISE EXCEPTION 'You can only act on your own behalf' USING ERRCODE = '42501';
    END IF;
    IF p_outcome NOT IN ('completed','no_show') THEN
        RAISE EXCEPTION 'Outcome must be completed or no_show' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_appt FROM appointment WHERE appointment_id = p_appt FOR UPDATE;
    IF NOT FOUND OR v_appt.therapist_id <> p_therapist THEN
        RAISE EXCEPTION 'Appointment not found for this therapist' USING ERRCODE = 'P0002';
    END IF;
    IF v_appt.status <> 'scheduled' THEN
        RAISE EXCEPTION 'Appointment is already %', v_appt.status USING ERRCODE = 'P0001';
    END IF;
    IF v_appt.start_time > now() THEN
        RAISE EXCEPTION 'Session has not started yet' USING ERRCODE = 'P0001';
    END IF;
    UPDATE appointment SET status = p_outcome WHERE appointment_id = p_appt;
    IF p_note IS NOT NULL THEN
        INSERT INTO session_note(appointment_id, therapist_id, note_text) VALUES (p_appt, p_therapist, p_note);
    END IF;
END $$;
