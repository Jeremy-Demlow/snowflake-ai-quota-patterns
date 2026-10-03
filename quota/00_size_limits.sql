-- ============================================================================
-- 00_size_limits.sql - size per-user AI quota limits from your own usage
-- ============================================================================
-- Run this IN YOUR OWN ACCOUNT. Read-only: SELECT only.
-- Needs a role that can read SNOWFLAKE.ACCOUNT_USAGE, e.g. ACCOUNTADMIN or a
-- role with the SNOWFLAKE.USAGE_VIEWER database role.
--
-- PURPOSE
--   Produce the numbers that go into quotas.yml. Do not set limits from a
--   guess, and do not set the daily limit to monthly / 30.
--
-- SIZING RULE
--   daily   ~ p95 of a heavy user's single day (covers normal peaks,
--             still stops a runaway)
--   weekly  ~ 2-3 x daily
--   monthly = the budget, and must stay below daily x days_in_month
--
-- LATENCY
--   ACCOUNT_USAGE views lag. Treat the most recent day as incomplete.
--   Credits are AI credits and are NOT interchangeable with warehouse credits.
--
-- NOT COVERED
--   Cortex Search is not a per-user quota domain and is excluded here on
--   purpose: measuring it would imply you can govern it with a quota.
-- ============================================================================

SET lookback_days = 120;

-- The standard-tier limits you are considering. Queries 2 and 3 test them.
SET proposed_daily   = 50;
SET proposed_monthly = 250;

-- ----------------------------------------------------------------------------
-- QUERY 1: per user, per domain. The main sizing output.
-- Feed p95_day into the tier daily limit and busiest_month into monthly.
-- ----------------------------------------------------------------------------
WITH per_day AS (
    SELECT USER_NAME AS user_name, NULL::NUMBER AS user_id,
           'CORTEX CODE' AS domain,
           LOWER(INTERFACE) AS surface,
           DATE(USAGE_TIME) AS d,
           SUM(TOKEN_CREDITS) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY
    WHERE USAGE_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
    GROUP BY 1, 2, 3, 4, 5

    UNION ALL

    SELECT u.NAME, h.USER_ID, 'AI FUNCTION', LOWER(h.FUNCTION_NAME),
           DATE(h.START_TIME), SUM(h.CREDITS)
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
    LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.USER_ID = h.USER_ID
    WHERE h.START_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
    GROUP BY 1, 2, 3, 4, 5
), rolled AS (
    SELECT COALESCE(user_name, 'USER_ID=' || user_id::VARCHAR, '(unattributed)') AS user_name,
           domain,
           SUM(credits) AS total_credits,
           COUNT(DISTINCT d) AS active_days,
           MAX(credits) AS worst_day,
           APPROX_PERCENTILE(credits, 0.95) AS p95_day,
           APPROX_PERCENTILE(credits, 0.50) AS median_day,
           ARRAY_AGG(DISTINCT surface) WITHIN GROUP (ORDER BY surface) AS surfaces
    FROM per_day
    GROUP BY 1, 2
), monthly AS (
    SELECT COALESCE(user_name, 'USER_ID=' || user_id::VARCHAR, '(unattributed)') AS user_name,
           domain,
           MAX(month_credits) AS busiest_month
    FROM (
        SELECT user_name, user_id, domain, DATE_TRUNC('month', d) AS m,
               SUM(credits) AS month_credits
        FROM per_day GROUP BY 1, 2, 3, 4
    ) GROUP BY 1, 2
)
SELECT r.user_name,
       u.TYPE AS user_type,
       u.DISABLED AS login_disabled,
       r.domain,
       ROUND(r.total_credits, 1) AS total_credits,
       r.active_days,
       ROUND(m.busiest_month, 1) AS busiest_month,
       ROUND(r.worst_day, 1) AS worst_day,
       ROUND(r.p95_day, 1) AS p95_day,
       ROUND(r.median_day, 1) AS median_day,
       r.surfaces,
       -- Suggested tier. Illustrative boundaries, not a product default.
       -- Replace them with your own policy.
       CASE
           WHEN u.TYPE = 'SERVICE' OR u.TYPE = 'LEGACY_SERVICE' THEN 'service (owner must size)'
           WHEN m.busiest_month > 1000 OR r.worst_day > 600 THEN 'service or redesign - investigate'
           WHEN m.busiest_month > 400  OR r.worst_day > 300 THEN 'intensive'
           ELSE 'standard'
       END AS suggested_tier
FROM rolled r
JOIN monthly m ON m.user_name = r.user_name AND m.domain = r.domain
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u
       ON u.NAME = r.user_name AND u.DELETED_ON IS NULL
WHERE r.total_credits >= 1
ORDER BY r.total_credits DESC;

-- ----------------------------------------------------------------------------
-- QUERY 2: per user, all domains combined. This is what a quota actually
-- enforces, because one quota covers all attached domains together.
-- ----------------------------------------------------------------------------
WITH per_day AS (
    SELECT USER_NAME AS user_name, DATE(USAGE_TIME) AS d, SUM(TOKEN_CREDITS) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY
    WHERE USAGE_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
    GROUP BY 1, 2
    UNION ALL
    SELECT u.NAME, DATE(h.START_TIME), SUM(h.CREDITS)
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
    LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.USER_ID = h.USER_ID
    WHERE h.START_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
    GROUP BY 1, 2
), combined AS (
    SELECT COALESCE(user_name, '(unattributed)') AS user_name, d, SUM(credits) AS credits
    FROM per_day GROUP BY 1, 2
)
SELECT c.user_name,
       u.TYPE AS user_type,
       ROUND(SUM(c.credits), 1) AS total_credits,
       COUNT(*) AS active_days,
       ROUND(MAX(c.credits), 1) AS worst_day,
       ROUND(APPROX_PERCENTILE(c.credits, 0.95), 1) AS p95_day,
       ROUND(MAX(mo.month_credits), 1) AS busiest_month,
       -- Proposed limits, then whether this user would actually be stopped.
       -- Change $proposed_daily / $proposed_monthly at the top of the file.
       $proposed_daily AS proposed_daily,
       $proposed_monthly AS proposed_monthly,
       IFF(MAX(c.credits) > $proposed_daily, 'WOULD BLOCK ON DAILY', 'ok') AS daily_check,
       IFF(MAX(mo.month_credits) > $proposed_monthly, 'WOULD BLOCK ON MONTHLY', 'ok') AS monthly_check
FROM combined c
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u
       ON u.NAME = c.user_name AND u.DELETED_ON IS NULL
LEFT JOIN (
    SELECT user_name, DATE_TRUNC('month', d) AS m, SUM(credits) AS month_credits
    FROM combined GROUP BY 1, 2
) mo ON mo.user_name = c.user_name
GROUP BY c.user_name, u.TYPE
ORDER BY total_credits DESC;

-- ----------------------------------------------------------------------------
-- QUERY 3: worst-case account exposure. The number Finance will ask for.
-- A per-user quota does NOT cap the account; N users x the daily limit does.
-- ----------------------------------------------------------------------------
WITH active_ai_users AS (
    SELECT DISTINCT USER_NAME AS user_name
    FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY
    WHERE USAGE_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
      AND USER_NAME IS NOT NULL
    UNION
    SELECT DISTINCT u.NAME
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
    JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.USER_ID = h.USER_ID
    WHERE h.START_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
)
SELECT COUNT(*) AS users_with_ai_usage,
       COUNT(*) * $proposed_daily AS worst_case_daily,
       COUNT(*) * $proposed_monthly AS worst_case_monthly,
       'Every user in the account is in scope unless excluded; a new user is '
         || 'governed on creation. This count reflects users with RECENT usage '
         || 'only, so the true ceiling is higher.' AS caveat
FROM active_ai_users;

-- ----------------------------------------------------------------------------
-- QUERY 4: expensive-model concentration. A quota cannot stop a single
-- costly query; only model RBAC can. Look for high credits_per_query on
-- Opus-class models: a handful of long-context calls can cost more than a
-- standard user's monthly limit.
-- ----------------------------------------------------------------------------
SELECT COALESCE(u.NAME, 'USER_ID=' || h.USER_ID::VARCHAR) AS user_name,
       h.MODEL_NAME,
       h.FUNCTION_NAME,
       ROUND(SUM(h.CREDITS), 1) AS credits,
       COUNT(DISTINCT h.QUERY_ID) AS queries,
       ROUND(SUM(h.CREDITS) / NULLIF(COUNT(DISTINCT h.QUERY_ID), 0), 2) AS credits_per_query,
       COUNT(DISTINCT DATE(h.START_TIME)) AS active_days
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.USER_ID = h.USER_ID
WHERE h.START_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3
HAVING SUM(h.CREDITS) >= 1
ORDER BY credits_per_query DESC NULLS LAST
LIMIT 50;
