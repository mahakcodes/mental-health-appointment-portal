-- =====================================================================
-- Mental Health Appointment Portal  |  PostgreSQL 14+
-- 01_schema.sql : DDL (types, tables, constraints, indexes)
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- needed for EXCLUDE constraints
CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- password hashing (crypt / gen_salt)

DROP SCHEMA IF EXISTS portal CASCADE;
CREATE SCHEMA portal;
SET search_path = portal, public;

-- ---------- Enumerated types ----------
CREATE TYPE user_role   AS ENUM ('patient', 'therapist', 'admin');
CREATE TYPE appt_status AS ENUM ('scheduled', 'completed', 'cancelled', 'no_show');

-- ---------- Core identity table (supertype for all roles) ----------
CREATE TABLE app_user (
    user_id        SERIAL PRIMARY KEY,
    email          VARCHAR(254) NOT NULL UNIQUE
                   CHECK (email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'),
    password_hash  TEXT         NOT NULL,
    role           user_role    NOT NULL,
    full_name      VARCHAR(100) NOT NULL,
    phone          VARCHAR(20)  CHECK (phone ~ '^[0-9+\- ]{7,20}$'),
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------- Role subtype tables (1:1 with app_user) ----------
CREATE TABLE patient (
    patient_id              INT PRIMARY KEY REFERENCES app_user(user_id) ON DELETE CASCADE,
    date_of_birth           DATE NOT NULL CHECK (date_of_birth < CURRENT_DATE),
    gender                  VARCHAR(20),
    emergency_contact_name  VARCHAR(100),
    emergency_contact_phone VARCHAR(20)
);

CREATE TABLE specialization (
    specialization_id SERIAL PRIMARY KEY,
    name              VARCHAR(80) NOT NULL UNIQUE
);

CREATE TABLE therapist (
    therapist_id     INT PRIMARY KEY REFERENCES app_user(user_id) ON DELETE CASCADE,
    license_no       VARCHAR(30) NOT NULL UNIQUE,
    years_experience SMALLINT    NOT NULL CHECK (years_experience BETWEEN 0 AND 60),
    session_fee      NUMERIC(8,2) NOT NULL CHECK (session_fee >= 0),
    bio              TEXT
);

-- M:N  therapist <-> specialization
CREATE TABLE therapist_specialization (
    therapist_id      INT NOT NULL REFERENCES therapist(therapist_id)           ON DELETE CASCADE,
    specialization_id INT NOT NULL REFERENCES specialization(specialization_id) ON DELETE RESTRICT,
    PRIMARY KEY (therapist_id, specialization_id)
);

-- ---------- Therapist availability (bookable slots) ----------
CREATE TABLE availability_slot (
    slot_id      SERIAL PRIMARY KEY,
    therapist_id INT         NOT NULL REFERENCES therapist(therapist_id) ON DELETE CASCADE,
    start_time   TIMESTAMPTZ NOT NULL,
    end_time     TIMESTAMPTZ NOT NULL,
    CONSTRAINT slot_valid_range CHECK (end_time > start_time),
    CONSTRAINT slot_max_length  CHECK (end_time - start_time <= INTERVAL '3 hours'),
    -- a therapist can never publish two overlapping slots
    CONSTRAINT slot_no_overlap EXCLUDE USING gist (
        therapist_id WITH =, tstzrange(start_time, end_time) WITH &&)
);

-- ---------- Appointments ----------
CREATE TABLE appointment (
    appointment_id SERIAL PRIMARY KEY,
    patient_id     INT          NOT NULL REFERENCES patient(patient_id)        ON DELETE RESTRICT,
    therapist_id   INT          NOT NULL REFERENCES therapist(therapist_id)    ON DELETE RESTRICT,
    slot_id        INT          NOT NULL REFERENCES availability_slot(slot_id) ON DELETE RESTRICT,
    start_time     TIMESTAMPTZ  NOT NULL,
    end_time       TIMESTAMPTZ  NOT NULL,
    status         appt_status  NOT NULL DEFAULT 'scheduled',
    reason         VARCHAR(500),
    cancelled_at   TIMESTAMPTZ,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT appt_valid_range CHECK (end_time > start_time),
    CONSTRAINT appt_cancel_consistency CHECK (
        (status = 'cancelled') = (cancelled_at IS NOT NULL))
);

-- Integrity safety nets (enforced by the DB even if app code has bugs / races):
-- 1) One active appointment per slot
CREATE UNIQUE INDEX uq_active_appt_per_slot
    ON appointment(slot_id) WHERE status = 'scheduled';
-- 2) A patient cannot hold two overlapping active appointments
ALTER TABLE appointment ADD CONSTRAINT appt_patient_no_overlap
    EXCLUDE USING gist (patient_id WITH =, tstzrange(start_time, end_time) WITH &&)
    WHERE (status = 'scheduled');
-- 3) A therapist cannot be double booked
ALTER TABLE appointment ADD CONSTRAINT appt_therapist_no_overlap
    EXCLUDE USING gist (therapist_id WITH =, tstzrange(start_time, end_time) WITH &&)
    WHERE (status = 'scheduled');

-- ---------- Confidential session notes (therapist-only) ----------
CREATE TABLE session_note (
    note_id        SERIAL PRIMARY KEY,
    appointment_id INT  NOT NULL UNIQUE REFERENCES appointment(appointment_id) ON DELETE CASCADE,
    therapist_id   INT  NOT NULL REFERENCES therapist(therapist_id),
    note_text      TEXT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- Audit trail ----------
CREATE TABLE audit_log (
    log_id     BIGSERIAL PRIMARY KEY,
    table_name TEXT        NOT NULL,
    action     TEXT        NOT NULL,
    row_id     INT,
    old_data   JSONB,
    new_data   JSONB,
    changed_by TEXT        NOT NULL DEFAULT current_user,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- Indexes for common access paths ----------
CREATE INDEX idx_slot_therapist_start ON availability_slot(therapist_id, start_time);
CREATE INDEX idx_appt_patient         ON appointment(patient_id, start_time);
CREATE INDEX idx_appt_therapist       ON appointment(therapist_id, start_time);
CREATE INDEX idx_appt_status          ON appointment(status);
CREATE INDEX idx_user_role            ON app_user(role);
