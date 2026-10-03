-- ============================================================================
-- 03_tier_intensive.sql - quota for human power users
-- ============================================================================
-- Run AFTER 02_tier_service.sql and BEFORE 04_tier_standard.sql.
--
-- WHY A SEPARATE TIER
--   Spend is usually heavily skewed: most people use a little, and one or two
--   power users use several times the median across CoCo, agents and AI
--   functions. This tier gives those people headroom without raising the
--   limit for everyone who does not need it.
--
-- WHAT THIS TIER IS NOT
--   It is not a budget increase mechanism for a one-off spike. For that, use
--   06_topup.sql, which is smaller and reversible.
--
-- EXAMPLE VALUES. Replace from quotas.yml after running 00_size_limits.sql.
-- ============================================================================

USE ROLE <QUOTA_OWNER_ROLE>;
USE WAREHOUSE <WAREHOUSE>;
USE SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;

-- --- 1. Create the quota -----------------------------------------------------
CREATE SNOWFLAKE.CORE.QUOTA IF NOT EXISTS QUOTA_AI_INTENSIVE();

-- --- 2. Scope to the intensive tag ------------------------------------------
-- A tag key holds ONE value per user, so a user can never be both intensive
-- and standard. That is what makes the tiers mutually exclusive.
CALL QUOTA_AI_INTENSIVE!SET_USER_TAGS(
    [[(SELECT SYSTEM$REFERENCE('TAG', '<CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER', 'SESSION', 'APPLYBUDGET')), 'intensive']],
    'UNION'
);

-- --- 3. Attach the monitored domains ----------------------------------------
CALL QUOTA_AI_INTENSIVE!ADD_SHARED_RESOURCE('AI FUNCTION');
CALL QUOTA_AI_INTENSIVE!ADD_SHARED_RESOURCE('CORTEX CODE');
CALL QUOTA_AI_INTENSIVE!ADD_SHARED_RESOURCE('CORTEX AGENT');
CALL QUOTA_AI_INTENSIVE!ADD_SHARED_RESOURCE('SNOWFLAKE INTELLIGENCE');

-- --- 4. Set the limits: DAILY FIRST -----------------------------------------
-- Sizing rule: daily < weekly < monthly < daily x days_in_month.
-- 150 x 30 = 4,500 > 2,000, so monthly is the real budget and daily only
-- caps bursts. Example numbers: size yours with 00_size_limits.sql.
CALL QUOTA_AI_INTENSIVE!SET_PER_USER_LIMIT(150,  'DAILY');
CALL QUOTA_AI_INTENSIVE!SET_PER_USER_LIMIT(600,  'WEEKLY');
CALL QUOTA_AI_INTENSIVE!SET_PER_USER_LIMIT(2000, 'MONTHLY');

-- --- 5. Notifications -------------------------------------------------------
CALL QUOTA_AI_INTENSIVE!SET_ADMIN_EMAILS('<QUOTA_ADMIN_EMAILS>');
CALL QUOTA_AI_INTENSIVE!ADD_NOTIFICATION_THRESHOLD(75, 'PROJECTED', TRUE, 'MONTHLY');
CALL QUOTA_AI_INTENSIVE!ADD_NOTIFICATION_THRESHOLD(90, 'ACTUAL',    TRUE, 'MONTHLY');
CALL QUOTA_AI_INTENSIVE!ADD_NOTIFICATION_THRESHOLD(90, 'ACTUAL',    TRUE, 'DAILY');

-- --- 6. Read the scope back -------------------------------------------------
-- Confirm your quota operator is here. That is the protection that keeps the
-- operator out of the 250-credit standard tier.
CALL QUOTA_AI_INTENSIVE!GET_QUOTA_SCOPE();
CALL QUOTA_AI_INTENSIVE!GET_CONFIG();
CALL QUOTA_AI_INTENSIVE!GET_USERS();

-- This file deliberately does NOT enable blocking. The quota is observe-only
-- until 07_enable_blocking.sql runs, after scope changes have propagated.
