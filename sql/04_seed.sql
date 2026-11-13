-- =====================================================================
-- 04_seed.sql : demo data (DML).  All demo passwords: Password@123
-- =====================================================================
SET search_path = portal, public;

INSERT INTO app_user(email, password_hash, role, full_name, phone) VALUES
 ('admin@mhportal.test',     crypt('Password@123', gen_salt('bf')), 'admin',     'Portal Admin',      '9000000001'),
 ('dr.sharma@mhportal.test', crypt('Password@123', gen_salt('bf')), 'therapist', 'Dr. Anita Sharma',  '9000000011'),
 ('dr.mehta@mhportal.test',  crypt('Password@123', gen_salt('bf')), 'therapist', 'Dr. Rohan Mehta',   '9000000012'),
 ('dr.iyer@mhportal.test',   crypt('Password@123', gen_salt('bf')), 'therapist', 'Dr. Kavya Iyer',    '9000000013'),
 ('riya@mhportal.test',      crypt('Password@123', gen_salt('bf')), 'patient',   'Riya Verma',        '9000000021'),
 ('arjun@mhportal.test',     crypt('Password@123', gen_salt('bf')), 'patient',   'Arjun Singh',       '9000000022'),
 ('neha@mhportal.test',      crypt('Password@123', gen_salt('bf')), 'patient',   'Neha Gupta',        '9000000023'),
 ('kabir@mhportal.test',     crypt('Password@123', gen_salt('bf')), 'patient',   'Kabir Joshi',       '9000000024');
-- ids: 1 admin | 2,3,4 therapists | 5,6,7,8 patients

INSERT INTO specialization(name) VALUES
 ('Anxiety Disorders'), ('Depression'), ('Cognitive Behavioural Therapy'),
 ('Trauma & PTSD'), ('Stress Management'), ('Adolescent Counselling');

INSERT INTO therapist(therapist_id, license_no, years_experience, session_fee, bio) VALUES
 (2, 'RCI-10021', 12, 1500.00, 'Clinical psychologist focused on anxiety and CBT.'),
 (3, 'RCI-10034',  8, 1200.00, 'Counsellor specialising in depression and stress.'),
 (4, 'RCI-10077',  5,  900.00, 'Works with adolescents and young adults.');

INSERT INTO therapist_specialization VALUES (2,1),(2,3),(3,2),(3,5),(4,6),(4,1),(4,4);

INSERT INTO patient(patient_id, date_of_birth, gender, emergency_contact_name, emergency_contact_phone) VALUES
 (5, '2001-03-14', 'Female', 'Sunita Verma', '9111111111'),
 (6, '1999-11-02', 'Male',   'Rakesh Singh', '9111111112'),
 (7, '2002-07-21', 'Female', 'Pooja Gupta',  '9111111113'),
 (8, '2000-01-30', 'Male',   'Meena Joshi',  '9111111114');

-- Historical slots + completed sessions (analytics data) -- inserted before future data
INSERT INTO availability_slot(therapist_id, start_time, end_time) VALUES
 (2, now() - interval '10 days', now() - interval '10 days' + interval '1 hour'),
 (3, now() - interval '8 days',  now() - interval '8 days'  + interval '1 hour'),
 (2, now() - interval '5 days',  now() - interval '5 days'  + interval '1 hour');
INSERT INTO appointment(patient_id, therapist_id, slot_id, start_time, end_time, status, reason)
SELECT 8, s.therapist_id, s.slot_id, s.start_time, s.end_time, 'completed', 'Follow-up'
FROM availability_slot s WHERE s.start_time < now();

-- 1-hour slots 10:00-16:00 for the next 14 days (no Sundays), every therapist
INSERT INTO availability_slot(therapist_id, start_time, end_time)
SELECT t.therapist_id,
       (d::date + make_time(h,0,0))::timestamptz,
       (d::date + make_time(h+1,0,0))::timestamptz
FROM therapist t
CROSS JOIN generate_series(current_date + 2, current_date + 15, interval '1 day') d
CROSS JOIN generate_series(10, 15) h
WHERE EXTRACT(DOW FROM d) <> 0;

-- Future appointments through the safe booking function
SELECT book_appointment(5, (SELECT slot_id FROM availability_slot WHERE therapist_id=2 AND start_time>now() ORDER BY start_time LIMIT 1), 'Exam anxiety');
SELECT book_appointment(6, (SELECT slot_id FROM availability_slot WHERE therapist_id=3 AND start_time>now() ORDER BY start_time LIMIT 1), 'Low mood and sleep issues');
SELECT book_appointment(7, (SELECT slot_id FROM availability_slot WHERE therapist_id=2 AND start_time>now() ORDER BY start_time OFFSET 3 LIMIT 1), 'Stress management');

INSERT INTO session_note(appointment_id, therapist_id, note_text)
SELECT appointment_id, therapist_id, 'Patient engaged well; assigned breathing exercises.'
FROM appointment WHERE status='completed' ORDER BY appointment_id LIMIT 1;
