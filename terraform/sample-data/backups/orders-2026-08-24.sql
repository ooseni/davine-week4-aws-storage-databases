-- SYNTHETIC LAB DATA. A stand-in for a nightly logical backup of the orders database.
CREATE TABLE customers (customer_id text PRIMARY KEY, name text NOT NULL);
CREATE TABLE orders (
    order_id    bigint PRIMARY KEY,
    customer_id text NOT NULL REFERENCES customers (customer_id),
    total_usd   numeric(10, 2) NOT NULL CHECK (total_usd >= 0),
    placed_at   timestamptz NOT NULL
);
INSERT INTO customers VALUES ('CUST-1001', 'Ada Example'), ('CUST-1002', 'Ben Sample');
INSERT INTO orders VALUES (1, 'CUST-1001', 75.98, '2026-08-24T09:05:00Z');
