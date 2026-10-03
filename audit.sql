-- ============================================================================
-- audit.sql - does the account match what you think you approved?
-- ============================================================================
-- Read-only. Answers the question an auditor actually asks: who can invoke AI,
-- what are they spending, and is anyone getting access by a path you did not
-- intend.
--
-- Needs nothing but the quota scripts and, for the role-based columns, the
-- optional dcm/ layer. No record tables, no snapshots.
--
-- ----------------------------------------------------------------------------
-- BIND THESE THREE, then run any query below.
-- ----------------------------------------------------------------------------
SET role_prefix  = '<ROLE_PREFIX>';     -- the approved prefix from dcm/manifest.yml
SET tag_database = '<CONTROL_DB>';
SET tag_schema   = '<CONTROL_SCHEMA>';
SET lookback_days = 30;

-- ACCOUNT_USAGE latency is up to ~2 hours for most views and up to ~2 hours for
-- TAG_REFERENCES. Nothing here is a real-time authorization check.


-- ============================================================================
-- QUERIES
-- ============================================================================

-- ----------------------------------------------------------------------------
-- QUERY 1: the AI roster. Who holds a capability role, what tier, what spend.
-- ----------------------------------------------------------------------------
WITH package_roles AS (
    SELECT $role_prefix || '_EMPLOYEE_COCO'  AS role_name, 'COCO'        AS capability
    UNION ALL SELECT $role_prefix || '_EMPLOYEE_SQL',      'SQL'
    UNION ALL SELECT $role_prefix || '_SERVICE_SQL',       'SERVICE_SQL'
    UNION ALL SELECT $role_prefix || '_PREMIUM_MODELS',    'PREMIUM'
), live_users AS (
    SELECT USER_ID, NAME AS user_name, TYPE AS user_type, DISABLED
    FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
    WHERE DELETED_ON IS NULL
), observed_membership AS (
    SELECT g.GRANTEE_NAME AS user_name,
           MAX(CASE WHEN r.capability = 'COCO'        THEN 1 ELSE 0 END) AS has_coco,
           MAX(CASE WHEN r.capability = 'SQL'         THEN 1 ELSE 0 END) AS has_sql,
           MAX(CASE WHEN r.capability = 'SERVICE_SQL' THEN 1 ELSE 0 END) AS has_service_sql,
           MAX(CASE WHEN r.capability = 'PREMIUM'     THEN 1 ELSE 0 END) AS has_premium
    FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS g
    JOIN package_roles r ON r.role_name = g.ROLE
    WHERE g.DELETED_ON IS NULL
    GROUP BY g.GRANTEE_NAME
), tier_tag AS (
    SELECT OBJECT_ID AS user_id, TAG_VALUE AS tier
    FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
    WHERE DOMAIN = 'USER'
      AND TAG_NAME = 'AI_SPEND_TIER'
      AND TAG_DATABASE = $tag_database
      AND TAG_SCHEMA = $tag_schema
), ai_spend AS (
    SELECT USER_ID, CREDITS AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
    WHERE START_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
    UNION ALL
    SELECT USER_ID, TOKEN_CREDITS
    FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY
    WHERE USAGE_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
    UNION ALL
    SELECT USER_ID, TOKEN_CREDITS
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
    WHERE START_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
), spend_by_user AS (
    SELECT USER_ID, ROUND(SUM(credits), 2) AS credits
    FROM ai_spend
    GROUP BY USER_ID
)
SELECT u.user_name,
       u.user_type,
       u.DISABLED,
       COALESCE(t.tier, 'standard (no tag)') AS spend_tier,
       CASE WHEN m.has_coco        = 1 THEN 'Y' ELSE '-' END AS coco,
       CASE WHEN m.has_sql         = 1 THEN 'Y' ELSE '-' END AS sql_ai,
       CASE WHEN m.has_service_sql = 1 THEN 'Y' ELSE '-' END AS service_sql,
       CASE WHEN m.has_premium     = 1 THEN 'Y' ELSE '-' END AS premium_models,
       COALESCE(s.credits, 0) AS credits_in_window
FROM live_users u
JOIN observed_membership m ON m.user_name = u.user_name
LEFT JOIN tier_tag t ON t.user_id = u.USER_ID
LEFT JOIN spend_by_user s ON s.USER_ID = u.USER_ID
ORDER BY COALESCE(s.credits, 0) DESC, u.user_name;


-- ----------------------------------------------------------------------------
-- QUERY 2: exceptions that need no recorded intent to detect.
-- Every row is something to resolve or consciously accept.
-- ----------------------------------------------------------------------------
WITH package_roles AS (
    SELECT $role_prefix || '_EMPLOYEE_COCO'  AS role_name, 'COCO'        AS capability
    UNION ALL SELECT $role_prefix || '_EMPLOYEE_SQL',      'SQL'
    UNION ALL SELECT $role_prefix || '_SERVICE_SQL',       'SERVICE_SQL'
    UNION ALL SELECT $role_prefix || '_PREMIUM_MODELS',    'PREMIUM'
), live_users AS (
    SELECT USER_ID, NAME AS user_name, TYPE AS user_type, DISABLED
    FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
    WHERE DELETED_ON IS NULL
), observed_membership AS (
    SELECT g.GRANTEE_NAME AS user_name,
           MAX(CASE WHEN r.capability = 'SERVICE_SQL' THEN 1 ELSE 0 END) AS has_service_sql,
           MAX(CASE WHEN r.capability = 'PREMIUM'     THEN 1 ELSE 0 END) AS has_premium,
           COUNT(*) AS package_role_count
    FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS g
    JOIN package_roles r ON r.role_name = g.ROLE
    WHERE g.DELETED_ON IS NULL
    GROUP BY g.GRANTEE_NAME
), tier_tag AS (
    SELECT OBJECT_ID AS user_id, TAG_VALUE AS tier
    FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
    WHERE DOMAIN = 'USER'
      AND TAG_NAME = 'AI_SPEND_TIER'
      AND TAG_DATABASE = $tag_database
      AND TAG_SCHEMA = $tag_schema
), joined AS (
    SELECT u.user_name, u.user_type, u.DISABLED,
           COALESCE(m.package_role_count, 0) AS package_role_count,
           COALESCE(m.has_service_sql, 0) AS has_service_sql,
           COALESCE(m.has_premium, 0) AS has_premium,
           t.tier
    FROM live_users u
    LEFT JOIN observed_membership m ON m.user_name = u.user_name
    LEFT JOIN tier_tag t ON t.user_id = u.USER_ID
)
SELECT exception_kind, severity, user_name, detail
FROM (
    -- A disabled identity that still holds AI roles. Cleanup was not finished.
    SELECT 'DISABLED_USER_RETAINS_AI_ROLE' AS exception_kind, 'MEDIUM' AS severity,
           user_name,
           'Disabled but still granted ' || package_role_count || ' package role(s); revoke to keep the roster honest' AS detail
    FROM joined WHERE DISABLED AND package_role_count > 0

    UNION ALL
    -- Premium model access. Always review; this is the expensive one.
    SELECT 'PREMIUM_MODEL_ACCESS', 'REVIEW', user_name,
           'Holds ' || $role_prefix || '_PREMIUM_MODELS. No quota prevents one expensive call; confirm this is still approved'
    FROM joined WHERE has_premium = 1

    UNION ALL
    -- A SERVICE identity in a human tier. Pipelines burst; humans do not.
    SELECT 'SERVICE_IDENTITY_IN_HUMAN_TIER', 'HIGH', user_name,
           'TYPE=SERVICE but tier is ' || COALESCE(tier, 'standard (no tag)') || '; batch AI belongs in the service tier'
    FROM joined WHERE user_type = 'SERVICE' AND COALESCE(tier, 'standard') <> 'service'

    UNION ALL
    -- Tagged into a tier but cannot invoke AI. The tag does nothing.
    SELECT 'TIER_TAG_WITHOUT_AI_ACCESS', 'LOW', user_name,
           'Tier is ' || tier || ' but holds no package capability role; tag has no effect'
    FROM joined WHERE tier IS NOT NULL AND package_role_count = 0

    UNION ALL
    -- Human holding the service role. Service roles carry workload models.
    SELECT 'PERSON_HOLDS_SERVICE_ROLE', 'MEDIUM', user_name,
           'TYPE=PERSON but holds ' || $role_prefix || '_SERVICE_SQL; confirm this is intended'
    FROM joined WHERE user_type = 'PERSON' AND has_service_sql = 1

    UNION ALL
    -- Left in a temporary top-up. These do not expire on their own.
    SELECT 'TOPUP_STILL_ACTIVE', 'MEDIUM', user_name,
           'Still tagged topup. INCLUDE_USERS has no TTL; see quota/06_topup.sql PART C'
    FROM joined WHERE tier = 'topup'
)
ORDER BY CASE severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'REVIEW' THEN 3 ELSE 4 END,
         exception_kind, user_name;


-- ----------------------------------------------------------------------------
-- QUERY 3: AI spend by identities that hold NO package role.
--
-- THIS IS THE QUERY THAT PROVES WHETHER REVOKING PUBLIC'S AI ACCESS WORKED.
--
-- Every row is someone invoking AI through a path this package does not own:
-- PUBLIC inheritance, a legacy role, a direct grant, ACCOUNTADMIN, or an
-- application. Until this returns only identities you can explain, Layer 1 is
-- describing access rather than controlling it.
--
-- Expect rows for ACCOUNTADMIN (inherent model access) and for Snowflake's own
-- service identities. Everything else is a finding.
-- ----------------------------------------------------------------------------
WITH package_roles AS (
    SELECT $role_prefix || '_EMPLOYEE_COCO'  AS role_name
    UNION ALL SELECT $role_prefix || '_EMPLOYEE_SQL'
    UNION ALL SELECT $role_prefix || '_SERVICE_SQL'
    UNION ALL SELECT $role_prefix || '_PREMIUM_MODELS'
), governed_users AS (
    SELECT DISTINCT g.GRANTEE_NAME AS user_name
    FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS g
    JOIN package_roles r ON r.role_name = g.ROLE
    WHERE g.DELETED_ON IS NULL
), ai_spend AS (
    SELECT USER_ID, 'AI_FUNCTION' AS surface, CREDITS AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
    WHERE START_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
    UNION ALL
    SELECT USER_ID, 'COCO_' || COALESCE(INTERFACE, 'UNKNOWN'), TOKEN_CREDITS
    FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY
    WHERE USAGE_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
    UNION ALL
    SELECT USER_ID, 'CORTEX_AGENT', TOKEN_CREDITS
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
    WHERE START_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
)
SELECT COALESCE(u.NAME, 'UNATTRIBUTED user_id ' || s.USER_ID::VARCHAR) AS user_name,
       u.TYPE AS user_type,
       ROUND(SUM(s.credits), 2) AS credits_in_window,
       COUNT(*) AS events,
       LISTAGG(DISTINCT s.surface, ', ') WITHIN GROUP (ORDER BY s.surface) AS surfaces,
       CASE
           WHEN u.NAME IS NULL THEN 'Cannot be governed by a per-user quota; no user attribution'
           WHEN u.TYPE = 'SERVICE' THEN 'Service identity outside the package; tag it and grant the service role'
           ELSE 'Human with AI access from another path; find the grant and close it'
       END AS finding
FROM ai_spend s
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u
       ON u.USER_ID = s.USER_ID AND u.DELETED_ON IS NULL
-- Anti-join, not NOT IN. A NOT IN subquery combined with the IS NULL case
-- raises "Unsupported subquery type cannot be evaluated" in Snowflake.
LEFT JOIN governed_users gu ON gu.user_name = u.NAME
WHERE gu.user_name IS NULL
GROUP BY u.NAME, u.TYPE, s.USER_ID
HAVING SUM(s.credits) > 0
ORDER BY credits_in_window DESC;


-- Before any roles are deployed, expect every credit in the account to appear
-- here: all spend is outside the package. After the capability roles are
-- granted and PUBLIC's inherited AI access is revoked (SNOWFLAKE.CORTEX_USER,
-- CORTEX-MODEL-ROLE-ALL), the human rows should disappear as those identities
-- move onto package roles.
--
-- An UNATTRIBUTED row will not disappear. Spend with no user attribution
-- cannot be governed by a per-user quota at all, in any account.
--
-- WHAT THIS FILE DOES NOT DO: compare the account against recorded approvals.
-- That record lives in your IdP and ticketing system. Query 3 is the part your
-- IdP cannot tell you.


-- ----------------------------------------------------------------------------
-- QUERY 4: quota change log. What changed on every quota, and when.
--
-- Every quota method that changes configuration writes an INFO event with a
-- readable message: limits, scope lists, tags, domains, thresholds, admin
-- emails, and every time blocking is switched on or off. Nothing to deploy.
--
-- The events go to the account's CONFIGURED event table, which is not always
-- SNOWFLAKE.TELEMETRY.EVENTS. If the docs' sample query returns nothing, the
-- account almost certainly points EVENT_TABLE somewhere else. This resolves it.
--
-- What it does NOT record: who made the change (see QUERY 5), and whether a
-- notification email was delivered. Do not use it as proof of delivery.
--
-- Validated in a demo account whose EVENT_TABLE is a custom table: this
-- resolved it automatically and returned every create, scope, limit,
-- threshold, admin-email and blocking change from two test deployments.
-- ----------------------------------------------------------------------------
SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT;
SET event_table = (SELECT COALESCE(NULLIF("value", ''), 'SNOWFLAKE.TELEMETRY.EVENTS')
                   FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
SELECT $event_table AS event_table_in_use;

SELECT TIMESTAMP                                          AS event_at_utc,
       RESOURCE_ATTRIBUTES:"snow.cost.quota.name"::STRING AS quota_name,
       RECORD:name::STRING                                AS event_name,
       VALUE:message::STRING                              AS change
FROM IDENTIFIER($event_table)
WHERE SCOPE['name']::STRING = 'snow.cost.quota'
  AND TIMESTAMP >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
ORDER BY event_at_utc DESC;

-- The single most important filter: every time blocking was switched.
--   AND RECORD:name::STRING = 'QUOTA_BLOCK_ENFORCEMENT_ENABLED_UPDATED'


-- ----------------------------------------------------------------------------
-- QUERY 5: who ran each quota change. Pairs with QUERY 4.
--
-- QUERY_HISTORY lags up to ~45 minutes. Read-only GET_ methods are excluded so
-- only changes remain. Match a row here to QUERY 4 by quota name and time.
-- A FAILED "EXECUTE IMMEDIATE" row is 07_enable_blocking.sql's gate refusing
-- to run on quotas that were too new: that is the gate working.
-- ----------------------------------------------------------------------------
SELECT START_TIME,
       USER_NAME,
       ROLE_NAME,
       EXECUTION_STATUS,
       LEFT(QUERY_TEXT, 300) AS statement
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -$lookback_days, CURRENT_TIMESTAMP())
  AND (   (QUERY_TEXT ILIKE '%QUOTA%!%' AND QUERY_TEXT NOT ILIKE '%!GET\\_%' ESCAPE '\\')
       OR QUERY_TEXT ILIKE '%SNOWFLAKE.CORE.QUOTA%')
  AND QUERY_TYPE IN ('CALL', 'CREATE', 'DROP', 'UNKNOWN')
ORDER BY START_TIME DESC;
