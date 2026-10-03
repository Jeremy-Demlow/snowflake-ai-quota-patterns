-- ============================================================================
-- 02_tier_service.sql - quota for service accounts running batch AI
-- ============================================================================
-- RUN THIS FIRST, before the intensive and standard tiers. A new quota defaults
-- to ALL USERS in the account, so the order matters: cover the heaviest
-- identities first, then narrow the standard tier around them.
--
-- WHY A SEPARATE TIER
--   A pipeline calling AI_COMPLETE over thousands of rows can spend more in a
--   day than a person spends in a month. That is a pipeline, not a person.
--   Putting it in a human tier either throttles the pipeline or inflates every
--   human's limit.
--
-- EXAMPLE VALUES. Replace from quotas.yml after sizing, and get the pipeline
-- owner to set the ceiling. Do not ship the example service numbers.
--
-- Run each numbered block separately and read the output before continuing.
-- ============================================================================

USE ROLE <QUOTA_OWNER_ROLE>;
USE WAREHOUSE <WAREHOUSE>;
USE SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;

-- --- 1. Create the quota -----------------------------------------------------
-- IF NOT EXISTS is for re-runnability, not permission to adopt someone else's
-- quota. If this already exists, stop and inspect it before changing anything.
CREATE SNOWFLAKE.CORE.QUOTA IF NOT EXISTS QUOTA_AI_SERVICE();

-- --- 2. Scope to the service tag --------------------------------------------
-- SET_USER_TAGS is atomic and idempotent: it REPLACES the whole tag list.
-- Requires APPLYBUDGET on the tag.
CALL QUOTA_AI_SERVICE!SET_USER_TAGS(
    [[(SELECT SYSTEM$REFERENCE('TAG', '<CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER', 'SESSION', 'APPLYBUDGET')), 'service']],
    'UNION'
);

-- --- 3. Attach the monitored domains ----------------------------------------
-- All four are block-enforceable. Cortex Search is NOT a quota domain and
-- cannot be added.
CALL QUOTA_AI_SERVICE!ADD_SHARED_RESOURCE('AI FUNCTION');
CALL QUOTA_AI_SERVICE!ADD_SHARED_RESOURCE('CORTEX CODE');
CALL QUOTA_AI_SERVICE!ADD_SHARED_RESOURCE('CORTEX AGENT');
CALL QUOTA_AI_SERVICE!ADD_SHARED_RESOURCE('SNOWFLAKE INTELLIGENCE');

-- --- 4. Set the limits: DAILY FIRST -----------------------------------------
-- Daily is the blast-radius control: the only one that caps a runaway batch
-- before it becomes a month's budget. Set it before monthly so the burst cap
-- exists first.
-- 300 x 30 = 9,000 > 3,000. EXAMPLE numbers: the pipeline owner sets the
-- real ceiling, and 00_size_limits.sql shows what the pipeline actually spends.
CALL QUOTA_AI_SERVICE!SET_PER_USER_LIMIT(300,  'DAILY');
CALL QUOTA_AI_SERVICE!SET_PER_USER_LIMIT(1000, 'WEEKLY');
CALL QUOTA_AI_SERVICE!SET_PER_USER_LIMIT(3000, 'MONTHLY');

-- --- 5. Notifications -------------------------------------------------------
-- Each address must be verified or the send is skipped and only an
-- informational event is logged. For a real service account, notify the OWNER,
-- not the unattended identity.
CALL QUOTA_AI_SERVICE!SET_ADMIN_EMAILS('<QUOTA_ADMIN_EMAILS>');
CALL QUOTA_AI_SERVICE!ADD_NOTIFICATION_THRESHOLD(75, 'PROJECTED', TRUE, 'MONTHLY');
CALL QUOTA_AI_SERVICE!ADD_NOTIFICATION_THRESHOLD(90, 'ACTUAL',    TRUE, 'MONTHLY');
CALL QUOTA_AI_SERVICE!ADD_NOTIFICATION_THRESHOLD(90, 'ACTUAL',    TRUE, 'DAILY');

-- --- 6. Read the scope back -------------------------------------------------
-- Confirm the four domains, the service tag, and that no unintended identity
-- is in scope. Tag resolution can lag roughly two hours, so an empty GET_USERS
-- immediately after tagging is expected and is not a failure.
CALL QUOTA_AI_SERVICE!GET_QUOTA_SCOPE();
CALL QUOTA_AI_SERVICE!GET_CONFIG();
CALL QUOTA_AI_SERVICE!GET_USERS();

-- This file deliberately does NOT enable blocking. The quota is observe-only
-- until 07_enable_blocking.sql runs, after scope changes have propagated.
