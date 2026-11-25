-- ICT371 Advanced Databases | Question 6
-- Monthly Payroll Processing
-- Run once in a database where you can create a fresh schema.
-- This script creates and uses ict371_q06.
-- The scheduler registration at the end is optional to execute.

BEGIN;

-- (a) Database and seed data
-- Each employee can have one payroll row per month. Run the seed payroll calls after
-- parts (b)–(d). The sample then makes one employee inactive to demonstrate that the
-- view retains past payroll.
CREATE SCHEMA ict371_q06;
SET search_path = ict371_q06, pg_catalog;
SET TIME ZONE 'Africa/Lusaka';

CREATE TABLE employees (
    employee_id integer PRIMARY KEY,
    full_name text NOT NULL,
    basic_salary numeric(12,2) NOT NULL
        CHECK (basic_salary >= 0 AND basic_salary <> 'NaN'),
    allowance numeric(12,2) NOT NULL
        CHECK (allowance >= 0 AND allowance <> 'NaN'),
    deduction numeric(12,2) NOT NULL
        CHECK (deduction >= 0 AND deduction <> 'NaN'),
    active boolean NOT NULL DEFAULT true
);

CREATE TABLE payroll (
    payroll_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id integer NOT NULL REFERENCES employees,
    pay_month date NOT NULL
        CHECK (isfinite(pay_month) AND EXTRACT(DAY FROM pay_month) = 1),
    gross_pay numeric(13,2) NOT NULL
        CHECK (gross_pay >= 0 AND gross_pay <> 'NaN'),
    net_pay numeric(13,2) NOT NULL CHECK (net_pay BETWEEN 0 AND gross_pay),
    UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id integer NOT NULL REFERENCES employees,
    old_salary numeric(12,2) NOT NULL,
    new_salary numeric(12,2) NOT NULL,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO employees VALUES
    (1, 'Ruth Banda', 5000.00, 600.00, 450.00, true),
    (2, 'David Phiri', 4200.00, 400.00, 250.00, true),
    (3, 'Mary Zulu',   3900.00, 350.00, 200.00, false);

-- (b) Function
-- Net pay is basic salary plus allowance minus deduction. The function raises an
-- exception if the result would be negative.
CREATE FUNCTION fn_net_pay(p_employee_id integer)
RETURNS numeric LANGUAGE plpgsql SET search_path = ict371_q06, pg_catalog AS $$
DECLARE
    v_net numeric;
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee ID: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay for employee %', p_employee_id;
    END IF;
    RETURN v_net;
END;
$$;

-- (c) Procedure
-- The query FOR loop processes active employees whose payroll row is missing. An
-- exception from fn_net_pay rolls back the entire call. ON CONFLICT DO NOTHING protects
-- existing payroll if another run inserts first.
CREATE PROCEDURE pr_process_payroll(p_month date)
LANGUAGE plpgsql SET search_path = ict371_q06, pg_catalog AS $$
DECLARE
    v_employee record;
    v_net numeric;
BEGIN
    IF p_month IS NULL OR NOT isfinite(p_month)
       OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Pay month must be the first date of a month';
    END IF;

    FOR v_employee IN
        SELECT e.employee_id, e.basic_salary, e.allowance
        FROM employees AS e
        WHERE e.active AND NOT EXISTS (
            SELECT 1 FROM payroll AS p
            WHERE p.employee_id = e.employee_id AND p.pay_month = p_month
        )
        ORDER BY e.employee_id
        FOR SHARE OF e
    LOOP
        v_net := fn_net_pay(v_employee.employee_id);
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (v_employee.employee_id, p_month,
                v_employee.basic_salary + v_employee.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- (d) Trigger
-- The trigger records the actual base salary change. An update limited to employee
-- activity creates zero audit rows.
CREATE FUNCTION fn_audit_basic_salary()
RETURNS trigger LANGUAGE plpgsql SET search_path = ict371_q06, pg_catalog AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_basic_salary
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION fn_audit_basic_salary();

-- (a) Deferred seed data, loaded after the routines and trigger
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

UPDATE employees
SET basic_salary = 5200.00, active = false
WHERE employee_id = 1;

-- (e) View
-- The report starts from saved payroll and joins employee names without filtering on
-- active. Ruth’s saved net pay remains K5,150.00 for both months.
CREATE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll AS p JOIN employees AS e USING (employee_id);

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index and execution plan
-- A pay_month index groups the month’s rows together across all employees. The existing
-- unique index leads with employee_id and serves employee-first searches.
CREATE INDEX idx_payroll_month ON payroll (pay_month);

EXPLAIN (COSTS OFF)
SELECT employee_id, gross_pay, net_pay FROM payroll
WHERE pay_month = DATE '2026-10-01';

-- Plan observed on the seed dataset:
-- Seq Scan on payroll
--   Filter: (pay_month = '2026-10-01'::date)
-- Index plan observed when sequential scans were discouraged:
-- Index Scan using idx_payroll_month on payroll
--   Index Cond: (pay_month = '2026-10-01'::date)

-- (g) Scheduled job
-- At 02:00 on the first day of each month, the job subtracts one month and takes the
-- first date of that month.

COMMIT;

-- Manual verification. The rollback preserves the original seed state.
BEGIN;
CALL pr_process_payroll(DATE '2026-10-01');
SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;
ROLLBACK;

-- The October rerun leaves four saved payroll rows across the two months. Run history
-- becomes available after execution if pg_cron run logging is enabled.

-- (g) Register the schedule when pg_cron is available.
-- Configure the server to preload pg_cron, set cron.database_name to this database and
-- set cron.timezone to Africa/Lusaka. Restart PostgreSQL, then select and run the
-- following block with its surrounding comment markers removed. Use an account allowed
-- to schedule and run the job.
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'ict371-q06',
    '0 2 1 * *',
    $job$
    SET TIME ZONE 'Africa/Lusaka';
    CALL ict371_q06.pr_process_payroll((date_trunc('month', CURRENT_DATE::timestamp) - INTERVAL '1 month')::date);
    $job$
);

SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'ict371-q06';

SELECT r.runid, r.status, r.start_time, r.end_time, r.return_message
FROM cron.job_run_details AS r
JOIN cron.job AS j USING (jobid)
WHERE j.jobname = 'ict371-q06'
ORDER BY r.start_time DESC;
*/
