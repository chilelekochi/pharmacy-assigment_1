-- =========================================================
-- QUESTION 1: PHARMACY STOCK AND DAILY SALES
-- PostgreSQL SQL script
-- Run this script in a database named pharmacy_db.
-- Create the database separately if it does not already exist:
-- CREATE DATABASE pharmacy_db;
-- =========================================================

-- (a) TABLES AND SEED DATA

CREATE TABLE medicines (
    medicine_id SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE stock_audit (
    audit_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty INTEGER NOT NULL,
    new_qty INTEGER NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INTEGER NOT NULL DEFAULT 0 CHECK (total_qty >= 0),
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0)
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty)
VALUES
('Paracetamol', 5.00, 100),
('Amoxicillin', 15.00, 80),
('Ibuprofen', 10.00, 60);


-- (b) FUNCTION: fn_sale_value
-- Returns current unit price multiplied by a positive quantity.

CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity. Quantity must be positive';
    END IF;

    SELECT unit_price
    INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine ID does not exist';
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- Function tests:
SELECT fn_sale_value(1, 5);
SELECT fn_sale_value(2, 3);
-- The following should raise errors:
-- SELECT fn_sale_value(1, 0);
-- SELECT fn_sale_value(99, 5);


-- (c) PROCEDURE: pr_record_sale
-- Checks stock, records the current price, and deducts stock once.
-- A failed procedure call is rolled back by PostgreSQL.

CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity INTEGER,
    p_sold_on TIMESTAMP
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock INTEGER;
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity. Quantity must be positive';
    END IF;

    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date cannot be NULL';
    END IF;

    SELECT stock_qty, unit_price
    INTO v_stock, v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine does not exist';
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock available';
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;


-- (d) TRIGGER: automatically audit stock changes.
-- Only records an audit row when stock_qty actually changes.

CREATE OR REPLACE FUNCTION fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
        INSERT INTO stock_audit (
            medicine_id, old_qty, new_qty, changed_at
        )
        VALUES (
            OLD.medicine_id,
            OLD.stock_qty,
            NEW.stock_qty,
            CURRENT_TIMESTAMP
        );
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION fn_stock_audit();


-- Six valid sales required by part (a).
-- These calls also demonstrate the procedure and stock audit trigger.

CALL pr_record_sale(1, 5, CURRENT_TIMESTAMP);
CALL pr_record_sale(2, 3, CURRENT_TIMESTAMP);
CALL pr_record_sale(3, 4, CURRENT_TIMESTAMP);
CALL pr_record_sale(1, 10, CURRENT_TIMESTAMP);
CALL pr_record_sale(2, 2, CURRENT_TIMESTAMP);
CALL pr_record_sale(3, 6, CURRENT_TIMESTAMP);

-- Test: unchanged stock should not create an audit record.
-- This UPDATE sets the current value to itself.
UPDATE medicines
SET stock_qty = stock_qty
WHERE medicine_id = 1;

-- Test invalid sales separately; each should raise an error:
-- CALL pr_record_sale(1, 0, CURRENT_TIMESTAMP);
-- CALL pr_record_sale(1, 1000, CURRENT_TIMESTAMP);
-- CALL pr_record_sale(99, 5, CURRENT_TIMESTAMP);


-- (e) VIEW: v_low_stock
-- Displays medicines with fewer than 10 units remaining.

CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- Demonstrate the view after a sale.
-- Medicine 1 has 85 units after the six sample sales.
-- Selling 76 leaves 9 units, so it appears in the view.
CALL pr_record_sale(1, 76, CURRENT_TIMESTAMP);
SELECT * FROM v_low_stock;


-- (f) INDEX: medicine sales within a sold_on date range.

CREATE INDEX idx_sales_medicine_sold_on
ON sales (medicine_id, sold_on);

EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
  AND sold_on >= TIMESTAMP '2026-11-01 00:00:00'
  AND sold_on <  TIMESTAMP '2026-12-01 00:00:00';

-- Verify the index:
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'sales';


-- (g) PROCEDURE: refresh one day's sales totals.
-- Replaces totals for the date; rerunning does not double-count.

CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_qty INTEGER;
    v_total_revenue NUMERIC(12,2);
BEGIN
    SELECT
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0)
    INTO v_total_qty, v_total_revenue
    FROM sales
    WHERE sold_on >= p_day
      AND sold_on < p_day + 1;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_total_qty, v_total_revenue)
    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Test and rerun for yesterday:
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales;

-- Scheduling at 00:15 daily requires pg_cron installed/configured
-- on the PostgreSQL server. Uncomment and run if pg_cron is available.
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule(
--     'daily_sales_refresh',
--     '15 0 * * *',
--     $$CALL pr_refresh_sales(CURRENT_DATE - 1);$$
-- );
-- Verify scheduled jobs:
-- SELECT * FROM cron.job;


-- FINAL VERIFICATION QUERIES

SELECT * FROM medicines;
SELECT * FROM sales;
SELECT * FROM stock_audit;
SELECT * FROM daily_sales;
SELECT * FROM v_low_stock;
