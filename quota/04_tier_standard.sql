-- ============================================================================
-- 04_tier_standard.sql - the default tier, covering everyone else
-- ============================================================================
-- RUN LAST, after 02_tier_service.sql and 03_tier_intensive.sql.
-- If you run this first, every heavy identity is briefly inside the low limit.
--
-- THE KEY DESIGN CHOICE
--   This quota keeps the DEFAULT all-users scope and EXCLUDES the other two
--   tiers by tag. It does not tag everyone 'standard'.
--
--   Why: a new user created next month is governed the moment they exist, with
--   no reconfiguration. If we tagged everyone explicitly instead, every new and
--   untagged user would be completely ungoverned, which is the opposite of the
--   requirement.
--
--   Cost of this choice: service and system identities are also in scope. That
--   is deliberate. Anything that genuinely needs more gets a tag.
--
-- EXAMPLE VALUES. Replace from quotas.yml after running 00_size_limits.sql.
-- ============================================================================

USE ROLE <QUOTA_OWNER_ROLE>;
USE WAREHOUSE <WAREHOUSE>;
USE SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;

-- --- 1. Create the quota -----------------------------------------------------
CREATE SNOWFLAKE.CORE.QUOTA IF NOT EXISTS QUOTA_AI_STANDARD();

-- --- 2. Scope: all users MINUS the other tiers -------------------------------
-- No SET_USER_TAGS call here. Omitting it keeps the default all-users scope.
-- EXCLUDE_USERS with tags carves out the identities that have their own quota.
CALL QUOTA_AI_STANDARD!EXCLUDE_USERS('TAG', [
    [(SELECT SYSTEM$REFERENCE('TAG', '<CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER', 'SESSION', 'APPLYBUDGET')), 'intensive'],
    [(SELECT SYSTEM$REFERENCE('TAG', '<CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER', 'SESSION', 'APPLYBUDGET')), 'service'],
    [(SELECT SYSTEM$REFERENCE('TAG', '<CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER', 'SESSION', 'APPLYBUDGET')), 'topup']
]);

-- --- 2b. OPTIONAL: name your quota operator as a safety net ------------------
-- A named exclusion takes precedence over tag scope AND survives a later tag
-- change, where a tag-based exclusion stops protecting someone the moment their
-- tag is removed.
--
-- Worth doing for whoever operates these quotas: an operator blocked by the
-- standard tier may lose access to the AI tooling they would use to diagnose and
-- fix it. Delete this block if you would rather the operator be governed like
-- everyone else.
--
-- Record this name. Reversing a top-up with an empty array clears this entire
-- list. See 06_topup.sql PART C3.
CALL QUOTA_AI_STANDARD!EXCLUDE_USERS('USER', ['<OPERATOR_USER>']);

-- --- 3. Attach the monitored domains ----------------------------------------
CALL QUOTA_AI_STANDARD!ADD_SHARED_RESOURCE('AI FUNCTION');
CALL QUOTA_AI_STANDARD!ADD_SHARED_RESOURCE('CORTEX CODE');
CALL QUOTA_AI_STANDARD!ADD_SHARED_RESOURCE('CORTEX AGENT');
CALL QUOTA_AI_STANDARD!ADD_SHARED_RESOURCE('SNOWFLAKE INTELLIGENCE');

-- --- 4. Set the limits: DAILY FIRST -----------------------------------------
-- Example: 50 / 120 / 250. Note 50 x 30 = 1,500 > 250, so monthly binds for
-- sustained use while daily still caps a single bad afternoon. Replace with
-- your own numbers from 00_size_limits.sql.
CALL QUOTA_AI_STANDARD!SET_PER_USER_LIMIT(50,  'DAILY');
CALL QUOTA_AI_STANDARD!SET_PER_USER_LIMIT(120, 'WEEKLY');
CALL QUOTA_AI_STANDARD!SET_PER_USER_LIMIT(250, 'MONTHLY');

-- --- 5. Notifications -------------------------------------------------------
CALL QUOTA_AI_STANDARD!SET_ADMIN_EMAILS('<QUOTA_ADMIN_EMAILS>');
CALL QUOTA_AI_STANDARD!ADD_NOTIFICATION_THRESHOLD(75, 'PROJECTED', TRUE, 'MONTHLY');
CALL QUOTA_AI_STANDARD!ADD_NOTIFICATION_THRESHOLD(90, 'ACTUAL',    TRUE, 'MONTHLY');
CALL QUOTA_AI_STANDARD!ADD_NOTIFICATION_THRESHOLD(90, 'ACTUAL',    TRUE, 'DAILY');

-- --- 6. Read the scope back -------------------------------------------------
-- <OPERATOR_USER> must appear in excluded_users.
CALL QUOTA_AI_STANDARD!GET_QUOTA_SCOPE();
CALL QUOTA_AI_STANDARD!GET_CONFIG();

-- This file deliberately does NOT enable blocking.
--
-- WHY: this quota is created with the default ALL USERS scope and narrowed a
-- few statements later. Scope changes take ~5-10 minutes to propagate. In a
-- Snowflake lab account, enabling blocking seconds after creation blocked the
-- operator on DAILY and MONTHLY even though GET_QUOTA_SCOPE already listed them
-- as excluded by tag AND by name. QUOTA_ACCESS_BLOCK_HISTORY shows BLOCKED on
-- both cycles, then UNBLOCKED 42 seconds later with no change made: the first
-- evaluation used the all-users scope, the next applied the exclusion. Brief,
-- but the block emails had already gone out.
--
-- A "STOP HERE" comment does not protect anyone when the file runs as
-- `snow sql -f`. Blocking lives in 07_enable_blocking.sql, run after a wait.
