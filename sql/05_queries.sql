-- =====================================================================
-- 05_queries.sql : DML / analytical queries (joins, aggregates, CTEs, windows)
-- =====================================================================
SET search_path = portal, public;

-- Q1. Open slots for a given specialization (multi-table JOIN)
SELECT v.therapist_name, s.name AS specialization, v.start_time, v.session_fee
FROM v_open_slots v
JOIN therapist_specialization ts ON ts.therapist_id = v.therapist_id
JOIN specialization s            ON s.specialization_id = ts.specialization_id
WHERE s.name = 'Anxiety Disorders'
ORDER BY v.start_time LIMIT 10;

-- Q2. A patient's upcoming appointments
SELECT appointment_id, therapist_name, start_time, status
FROM v_appointment_details
WHERE patient_id = 5 AND start_time > now() AND status = 'scheduled'
ORDER BY start_time;

-- Q3. Therapist workload + revenue (GROUP BY / HAVING)
SELECT u.full_name, count(*) FILTER (WHERE a.status='completed') AS completed,
       count(*) FILTER (WHERE a.status='scheduled') AS upcoming,
       sum(t.session_fee) FILTER (WHERE a.status='completed') AS revenue
FROM therapist t
JOIN app_user u ON u.user_id = t.therapist_id
LEFT JOIN appointment a ON a.therapist_id = t.therapist_id
GROUP BY u.full_name
HAVING count(a.appointment_id) > 0
ORDER BY revenue DESC NULLS LAST;

-- Q4. Slot utilisation % per therapist (CTE)
WITH slots AS (
  SELECT therapist_id, count(*) AS total FROM availability_slot GROUP BY therapist_id),
booked AS (
  SELECT therapist_id, count(*) AS booked FROM appointment WHERE status='scheduled' GROUP BY therapist_id)
SELECT u.full_name, s.total, coalesce(b.booked,0) AS booked,
       round(100.0*coalesce(b.booked,0)/s.total, 1) AS utilisation_pct
FROM slots s JOIN app_user u ON u.user_id = s.therapist_id
LEFT JOIN booked b USING (therapist_id)
ORDER BY utilisation_pct DESC;

-- Q5. Rank therapists by completed sessions (window function)
SELECT therapist_id, completed,
       RANK() OVER (ORDER BY completed DESC) AS rnk
FROM (SELECT therapist_id, count(*) AS completed
      FROM appointment WHERE status='completed' GROUP BY therapist_id) x;

-- Q6. Patients with no upcoming appointment (anti-join)
SELECT u.full_name FROM patient p JOIN app_user u ON u.user_id = p.patient_id
WHERE NOT EXISTS (SELECT 1 FROM appointment a
                  WHERE a.patient_id = p.patient_id AND a.status='scheduled');

-- Q7. Cancellation rate (aggregate + case)
SELECT round(100.0 * count(*) FILTER (WHERE status='cancelled') / NULLIF(count(*),0), 1) AS cancel_rate_pct
FROM appointment;

-- Q8. Busiest weekday/hour for bookings
SELECT to_char(start_time,'Dy') AS weekday, extract(hour FROM start_time) AS hr, count(*) AS bookings
FROM appointment GROUP BY 1,2 ORDER BY bookings DESC LIMIT 5;

-- Q9. Audit trail for one appointment
SELECT action, changed_by, changed_at, new_data->>'status' AS status_after
FROM audit_log WHERE table_name='appointment' AND row_id = 1 ORDER BY changed_at;

-- Q10. Index usage proof (run EXPLAIN ANALYZE; used in README "performance" section)
EXPLAIN ANALYZE
SELECT * FROM appointment WHERE therapist_id = 2 AND start_time > now() ORDER BY start_time;
