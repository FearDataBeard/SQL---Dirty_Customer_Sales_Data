
-- NOTE:
-- In an enterprise or production environment, the original `dirty_customer_sales` dataset would be duplicated
-- prior to profiling or transformation in order to preserve a "golden record" for audit, rollback, and data lineage purposes.
-- 
-- However, for this case study, the dataset is used in read-only mode.
-- All profiling is performed through a backup table, preserving compliance with DAMA-DMBOK governance practices
-- without altering or overwriting source data.
------------------------------------------------------------
-- CREATE BACKUP FROM MAIN FILE
------------------------------------------------------------
COMMENT ON TABLE dirty_customer_sales_backup IS 'Golden record backup before SQL data cleaning process';
DROP TABLE IF EXISTS dirty_customer_sales_backup;
CREATE TABLE dirty_customer_sales_backup AS
SELECT * FROM dirty_customer_sales;

------------------------------------------------------------
-- CREATE CustomerID for masking
------------------------------------------------------------
CREATE TABLE customer_names AS
SELECT DISTINCT customername
FROM dirty_customer_sales_backup
WHERE customername IS NOT NULL;

ALTER TABLE customer_names
ADD COLUMN name_id SERIAL PRIMARY KEY;

ALTER TABLE dirty_customer_sales_backup
ADD COLUMN name_id INT;

UPDATE dirty_customer_sales_backup AS D
SET name_id = n.name_id
FROM customer_names AS n
WHERE d.customername = n.customername;
------------------------------------------------------------
-- BASIC CONTROL
------------------------------------------------------------
SELECT * FROM dirty_customer_sales_backup;

------------------------------------------------------------
-- PROFILING
------------------------------------------------------------
-- Top Duplicate Candidates
SELECT customername, COUNT(*) AS  name_count
FROM dirty_customer_sales
GROUP BY customername
HAVING COUNT(*) > 1
ORDER BY name_count DESC;

-- Count inconsistant Booleans yes(100) y(107) null(100) No(95) N(97)
SELECT isactive, COUNT(*)
FROM dirty_customer_sales
GROUP BY isactive;

------------------------------------------------------------
-- CLEANING
------------------------------------------------------------
--Normalize customername
UPDATE dirty_customer_sales_backup
SET customername = INITCAP(TRIM(customername))
WHERE customername IS NOT NULL;
--Further Normalization on customername to first/last
ALTER TABLE dirty_customer_sales_backup
ADD COLUMN firstname text,
ADD COLUMN lastname text;
--Population of first/last name columns
UPDATE dirty_customer_sales_backup
SET firstname = INITCAP(TRIM(SPLIT_PART(customername, ' ', 1))),
	lastname = INITCAP(TRIM(SPLIT_PART(customername, ' ', 2)))
WHERE customername IS NOT NULL;
--Validate normalization
SELECT customername, COUNT(*)
FROM dirty_customer_sales_backup
GROUP BY customername
ORDER BY COUNT(*) DESC;
--Normalize region
UPDATE dirty_customer_sales_backup
SET region = INITCAP(TRIM(region))
WHERE region IS NOT NULL;
-- Rename region nulls with COALESCE to unknown
SELECT COALESCE(region, 'unknown')
FROM dirty_customer_sales_backup;
-- Update Region nulls and eliminate spacing
UPDATE dirty_customer_sales_backup
SET region = 'unknown'
WHERE region IS NULL OR TRIM(region) = '';
-- Email corrilation with name
ALTER TABLE dirty_customer_sales_backup ADD COLUMN email_mismatch BOOLEAN;

UPDATE dirty_customer_sales_backup
SET email_mismatch = NOT (
	    LOWER(email) LIKE '%' || LOWER(firstname) || '%'
    OR LOWER(email) LIKE '%' || LOWER(lastname) || '%'
)
WHERE email IS NOT NULL AND firstname IS NOT NULL AND lastname IS NOT NULL;
--Normalize email
UPDATE dirty_customer_sales_backup
SET email = TRIM(LOWER(email))
WHERE email IS NOT NULL;
-- Backfill customer name to email
UPDATE dirty_customer_sales_backup
SET email = CASE
	WHEN customername = 'Bob Lee' THEN 'unknown'
	WHEN customername = 'Sarah Connor' THEN 'sconnor@data.net'
	WHEN customername = 'Jane Smith' THEN 'janesmith@work.org'
	WHEN customername = 'John Doe' THEN 'johndoe@gmail.com'
	WHEN customername = 'Alice Johnson' THEN 'alice@email.com'
	ELSE email
END
WHERE customername IN (
	'Bob Lee', 
	'Sarah Connor', 
	'Jane Smith', 
	'John Doe', 
	'Alice Johnson');
-- Reverse backfill email back to customername
UPDATE dirty_customer_sales_backup
SET customername = CASE
	WHEN email = 'sconnor@data.net' THEN 'Sarah Conner'
	WHEN email =  'janesmith@work.org'THEN 'Jane Smith'
	WHEN email =  'johndoe@gmail.com'THEN 'John Doe'
	WHEN email =  'alice@email.com'THEN 'Alice Johnson'
	ELSE customername
END
WHERE email IN (
	'sconnor@data.net', 
	'janesmith@work.org', 
	'johndoe@gmail.com', 
	'alice@email.com');
--Validate normalization
SELECT email, COUNT(*)
FROM dirty_customer_sales_backup
GROUP BY email
ORDER BY COUNT(*) DESC;
-- After backfilling email to customername we can now up date the first and laste name column
UPDATE dirty_customer_sales_backup
SET firstname = INITCAP(TRIM(SPLIT_PART(customername, ' ', 1))),
	lastname = INITCAP(TRIM(SPLIT_PART(customername, ' ', 2)))
WHERE customername IS NOT NULL;
-- Clean isactive column 
SELECT isactive,
       CASE 
           WHEN isactive IN ('Yes', 'Y') THEN TRUE
           WHEN isactive IN ('No', 'N') THEN FALSE
           ELSE NULL
       END AS isactive_cleaned
FROM dirty_customer_sales;

UPDATE dirty_customer_sales_backup
SET isactive = CASE 
           WHEN isactive IN ('Yes', 'Y') THEN TRUE
           WHEN isactive IN ('No', 'N') THEN FALSE
           ELSE NULL
       END;
--Remove ',' for datatype change
UPDATE dirty_customer_sales_backup
SET revenue = REPLACE(revenue, ',', '')
WHERE revenue LIKE '%,%';

-- Signupdate and isactive were excluded from final analysis due to inconsistent 
--logic, unclear definitions, and no identifiable business value. Cleaning focused
-- on trustworthy fields (name, email, revenue, region) to preserve dataset integrity.
ALTER TABLE dirty_customer_sales_backup
DROP signupdate,
DROP isactive;

-- At this point there is no need for email_mismatch and will be dropped to keep
-- the dataset clean and organized.
ALTER TABLE dirty_customer_sales_backup
DROP email_mismatch;

-- Additional fields have been removed
-- If all 4 fields are missing then it is deleted from the table
BEGIN TRANSACTION;

DELETE FROM dirty_customer_sales_backup
WHERE 
  (customername IS NULL OR TRIM(customername) = 'null' OR TRIM(customername) = '')
  AND (email IS NULL OR TRIM(email) = 'null' OR TRIM(email) = '')
  AND (revenue IS NULL OR TRIM(revenue) = 'null' OR TRIM(revenue) = '')
  AND (region IS NULL OR TRIM(region) = 'null' OR TRIM(region) = '');

COMMIT;
-- If all 3 fields are missing and revenue is present then it is deleted from the table
BEGIN TRANSACTION;

DELETE FROM dirty_customer_sales_backup
WHERE
  (customername IS NULL OR TRIM(customername) = 'null' OR TRIM(customername) = '')
  AND (email IS NULL OR TRIM(email) = 'null' OR TRIM(email) = '')
  AND (region IS NULL OR TRIM(region) = 'null' OR TRIM(region) = '')
  AND (revenue IS NOT NULL);

COMMIT;
-- Additional fields must be removed if both revenue and region are missing, then it is deleted from the table
BEGIN TRANSACTION;

DELETE FROM dirty_customer_sales_backup
WHERE 
  (revenue IS NULL OR TRIM(revenue) = 'null' OR TRIM(revenue) = '')
  AND (region IS NULL OR TRIM(region) = 'null' OR TRIM(region) = '');

COMMIT;
-- if region is only missing then row is deleted
BEGIN TRANSACTION;

DELETE FROM dirty_customer_sales_backup
WHERE 
  (revenue IS NULL OR TRIM(revenue) = 'null' OR TRIM(revenue) = '');

COMMIT;
-- If customername and email is missing then row is deleted
BEGIN TRANSACTION;

DELETE FROM dirty_customer_sales_backup
WHERE
  (customername IS NULL OR TRIM(customername) = 'null' OR TRIM(customername) = '')
  AND (email IS NULL OR TRIM(email) = 'null' OR TRIM(email) = '');

COMMIT;
------------------------------------------------------------
-- TABLE MODIFICATIONS
------------------------------------------------------------
-- customername: change type + enforce NOT NULL
ALTER TABLE dirty_customer_sales_backup
ALTER COLUMN customername TYPE VARCHAR(50);

ALTER TABLE dirty_customer_sales_backup
ALTER COLUMN customername SET NOT NULL;

-- revenue: change type to INT + enforce NOT NULL
ALTER TABLE dirty_customer_sales_backup
ALTER COLUMN revenue TYPE NUMERIC(10,2) USING revenue::NUMERIC;

ALTER TABLE dirty_customer_sales_backup
ALTER COLUMN revenue SET NOT NULL;

-- email: change type + enforce NOT NULL
ALTER TABLE dirty_customer_sales_backup
ALTER COLUMN email TYPE VARCHAR(50);

ALTER TABLE dirty_customer_sales_backup
ALTER COLUMN email SET NOT NULL;

-- region: change type + enforce NOT NULL
ALTER TABLE dirty_customer_sales_backup
ALTER COLUMN region TYPE VARCHAR(7);

ALTER TABLE dirty_customer_sales_backup
ALTER COLUMN region SET NOT NULL;

------------------------------------------------------------
-- FINAL RESULTS
------------------------------------------------------------
WITH ranked_customers AS (
  SELECT 
    region,
    name_id,
    SUM(revenue) AS total_revenue,
    SUM(CASE WHEN revenue < 0 THEN revenue ELSE 0 END) AS total_refunds,
    RANK() OVER (PARTITION BY region ORDER BY SUM(revenue) DESC) AS top_rank,
    RANK() OVER (PARTITION BY region ORDER BY SUM(revenue) ASC) AS low_rank
  FROM dirty_customer_sales_backup
  WHERE region IN ('North', 'South', 'East', 'West')
  GROUP BY region, name_id
),

top_customers AS (
  SELECT 
    region, 
    name_id AS top_name_id, 
    total_revenue AS top_revenue, 
    total_refunds AS top_refunds,
    total_revenue - total_refunds AS projections
  FROM ranked_customers
  WHERE top_rank = 1
),

low_customers AS (
  SELECT 
    region, 
    name_id AS low_name_id, 
    total_revenue AS low_revenue
  FROM ranked_customers
  WHERE low_rank = 1
),

combined AS (
  SELECT 
    t.region,
    t.top_name_id,
    t.top_revenue,
    t.top_refunds,
    t.projections,
    l.low_name_id,
    l.low_revenue,
    0 AS sort_order  -- normal regions
  FROM top_customers t
  JOIN low_customers l ON t.region = l.region

  UNION ALL

  SELECT 
    'Total',
    NULL,
    SUM(top_revenue),
    SUM(top_refunds),
    SUM(projections),
    NULL,
    SUM(low_revenue),
    1 AS sort_order  -- total row comes last
  FROM (
    SELECT * FROM top_customers t
    JOIN low_customers l ON t.region = l.region
  ) AS sub
)

SELECT *
FROM combined
ORDER BY sort_order, region;


------------------------------------------------------------
-- My failed code, and why it failed
------------------------------------------------------------
-- Originally planned to use a materialized view for performance,
-- but after refining the logic, real-time queries were sufficient.
-- View logic removed for clarity and simplicity.
SELECT * FROM customer_sales_profile;
DROP MATERIALIZED VIEW IF EXISTS customer_sales_profile;
CREATE MATERIALIZED VIEW customer_sales_profile as
SELECT 'customerid' AS column_name,
       COUNT(customerid) AS total,
       COUNT(DISTINCT customerid) AS distinct_count,
       COUNT(CASE WHEN customerid IS NULL THEN 1 END) AS null_count
FROM dirty_customer_sales

UNION ALL

SELECT 'customername',
       COUNT(customername),
       COUNT(DISTINCT customername),
       COUNT(CASE WHEN customername IS NULL OR customername = 'null' THEN 1 END)
FROM dirty_customer_sales

UNION ALL

SELECT 'email',
       COUNT(email),
       COUNT(DISTINCT email),
       COUNT(CASE WHEN email IS NULL OR email = 'null' THEN 1 END)
FROM dirty_customer_sales

UNION ALL

SELECT 'signupdate',
       COUNT(signupdate),
       COUNT(DISTINCT signupdate),
       COUNT(CASE WHEN signupdate IS NULL OR signupdate = 'null' THEN 1 END)
FROM dirty_customer_sales

UNION ALL

SELECT 'revenue',
       COUNT(revenue),
       COUNT(DISTINCT revenue),
       COUNT(CASE WHEN revenue IS NULL OR revenue = 'null' THEN 1 END)
FROM dirty_customer_sales

UNION ALL

SELECT 'region',
       COUNT(region),
       COUNT(DISTINCT region),
       COUNT(CASE WHEN region IS NULL OR region = 'null' THEN 1 END)
FROM dirty_customer_sales;
-- Backfill failled and filled in incorrect
-- reverse fill from customername to email
UPDATE dirty_customer_sales_backup AS target
SET email = source.email
FROM (
    SELECT customername, MAX(email) AS email
    FROM dirty_customer_sales_backup
    WHERE email IS NOT NULL
    GROUP BY customername
    HAVING COUNT(DISTINCT email) = 1 -- ONLY names that map to 1 email
) AS source
WHERE target.email IS NULL
--During cleanup of duplicate customer records, I initially removed rows using a 
--partition on `customername`. This unexpectedly deleted all rows due to the 
--non-uniqueness of names in the dataset. This highlights the importance of backup 
--tables and validating partition logic before any destructive operation — especially when 
--transaction control is unavailable (as in some offline SQL environments).
SELECT * FROM dirty_customer_sales;
SELECT * FROM customer_sales_profile;
LIMIT 1;
WITH ranked_duplicates AS (
	SELECT 	customerid, customername,
		ROW_NUMBER() OVER (PARTITION BY customername ORDER BY customerid DESC) AS rn
	FROM dirty_customer_sales
)
SELECT rn, COUNT(*)
FROM ranked_duplicates
GROUP BY rn
ORDER BY rn;

SELECT *
FROM dirty_customer_sales
USING ranked_duplicates
WHERE dirty_customer_sales.customerid = ranked_duplicates.customerid
AND ranked_duplicates.rn > 1;
