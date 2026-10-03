-- ============================================================================
-- 99_teardown.sql - remove everything this package created. NON-PRODUCTION.
-- ============================================================================
-- Run this when you are finished demonstrating, so the demo account is clean.
--
-- ORDER MATTERS. Enforcement is disabled before the quotas are dropped so that
-- anyone currently blocked is released rather than left blocked by a quota that
-- no longer exists to release them.
--
--   1. disable enforcement   users unblock within ~5-10 minutes
--   2. drop quotas
--   3. unset tier tags       tags survive the quotas that read them
--   4. PURGE the DCM project (drops its roles and tags), then drop the project
--   5. verify empty
--
-- Validated end to end in a Snowflake lab account.
--
-- ----------------------------------------------------------------------------
-- WHAT THIS DOES NOT DO
-- ----------------------------------------------------------------------------
--   - Does not delete metering history. Credits already consumed stay consumed
--     and stay visible in ACCOUNT_USAGE. There is no refund.
--   - Does not restore PUBLIC's AI access if you revoked it. Re-granting
--     broad access is a separate risk decision, not a teardown step.
--   - Does not drop <CONTROL_DB> or the <CONTROL_SCHEMA> schema. Those predate this
--     package and may hold unrelated objects.
--   - Does not remove grants made outside the DCM project.
--
-- ----------------------------------------------------------------------------
-- GUARD: bind the account you intend to tear down, and verify before running.
-- ----------------------------------------------------------------------------
-- This drops every control this package created. Bind <EXPECTED_ACCOUNT_LOCATOR>
-- to the NON-PRODUCTION account you are tearing down. If the verdict below is
-- not "safe to tear down", STOP. Do not continue past this query.
SELECT CURRENT_ACCOUNT()  AS account_now,
       CURRENT_ROLE()     AS role_now,
       CASE WHEN CURRENT_ACCOUNT() = '<EXPECTED_ACCOUNT_LOCATOR>'
            THEN 'Expected account - safe to tear down'
            ELSE 'STOP - THIS IS NOT THE ACCOUNT YOU BOUND'
       END AS verdict;

USE ROLE <QUOTA_OWNER_ROLE>;
USE WAREHOUSE <WAREHOUSE>;
USE SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;


-- ============================================================================
-- STEP 0 - RECORD WHAT EXISTS, so you can confirm it is all gone at the end
-- ============================================================================
SHOW SNOWFLAKE.CORE.QUOTA INSTANCES IN ACCOUNT;

-- Anyone currently blocked. These users are released by step 1.
SELECT ACTION_AT, QUOTA_NAME, USER_NAME, CYCLE, ACTION,
       CREDITS, PER_USER_LIMIT, BLOCKED_UNTIL
FROM SNOWFLAKE.ACCOUNT_USAGE.QUOTA_ACCESS_BLOCK_HISTORY
WHERE BLOCKED_UNTIL > CURRENT_TIMESTAMP()
ORDER BY ACTION_AT DESC;

-- Everyone carrying a tier tag. Step 3 clears these; capture the list first
-- because TAG_REFERENCES lags up to ~2 hours and will not help you afterwards.
SELECT u.NAME AS user_name, t.TAG_VALUE AS tier
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS u
JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
  ON t.OBJECT_ID = u.USER_ID
 AND t.DOMAIN = 'USER'
 AND t.TAG_NAME = 'AI_SPEND_TIER'
 AND t.TAG_DATABASE = '<CONTROL_DB>'
 AND t.TAG_SCHEMA = '<CONTROL_SCHEMA>'
WHERE u.DELETED_ON IS NULL
ORDER BY user_name;


-- ============================================================================
-- STEP 1 - DISABLE ENFORCEMENT FIRST
-- ============================================================================
-- Do this before dropping anything. Blocked users are released within ~5-10
-- minutes. Dropping a quota also releases its blocks, but disabling first makes
-- the release observable and reversible if you change your mind mid-teardown.
CALL QUOTA_AI_STANDARD!SET_BLOCK_ENFORCEMENT_ENABLED(FALSE, FALSE);
CALL QUOTA_AI_INTENSIVE!SET_BLOCK_ENFORCEMENT_ENABLED(FALSE, FALSE);
CALL QUOTA_AI_SERVICE!SET_BLOCK_ENFORCEMENT_ENABLED(FALSE, FALSE);
CALL QUOTA_AI_TOPUP!SET_BLOCK_ENFORCEMENT_ENABLED(FALSE, FALSE);

-- Confirm nothing is still blocked before moving on.
CALL QUOTA_AI_STANDARD!GET_ACTIVE_BLOCKS_V2();
CALL QUOTA_AI_INTENSIVE!GET_ACTIVE_BLOCKS_V2();
CALL QUOTA_AI_SERVICE!GET_ACTIVE_BLOCKS_V2();
CALL QUOTA_AI_TOPUP!GET_ACTIVE_BLOCKS_V2();


-- ============================================================================
-- STEP 2 - DROP THE QUOTAS
-- ============================================================================
DROP SNOWFLAKE.CORE.QUOTA IF EXISTS <CONTROL_DB>.<CONTROL_SCHEMA>.QUOTA_AI_TOPUP;
DROP SNOWFLAKE.CORE.QUOTA IF EXISTS <CONTROL_DB>.<CONTROL_SCHEMA>.QUOTA_AI_STANDARD;
DROP SNOWFLAKE.CORE.QUOTA IF EXISTS <CONTROL_DB>.<CONTROL_SCHEMA>.QUOTA_AI_INTENSIVE;
DROP SNOWFLAKE.CORE.QUOTA IF EXISTS <CONTROL_DB>.<CONTROL_SCHEMA>.QUOTA_AI_SERVICE;

SHOW SNOWFLAKE.CORE.QUOTA INSTANCES IN ACCOUNT;


-- ============================================================================
-- STEP 3 - UNSET THE TIER TAGS
-- ============================================================================
-- Tags are independent of quotas and survive them. Use the list captured in
-- STEP 0; add a line per tagged user.
ALTER USER "<TAGGED_USER>" UNSET TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER;
-- ALTER USER "<ANOTHER_TAGGED_USER>" UNSET TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER;

-- Immediate read. Must return NULL. Do this BEFORE step 4 drops the tag object.
SELECT SYSTEM$GET_TAG('<CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER', '"<TAGGED_USER>"', 'USER') AS tier_now;

-- If AI_ELIGIBILITY or AI_COST_CENTER were applied, clear those too. Step 4
-- drops the tag objects, but an ALTER USER SET TAG that DCM did not manage is
-- not automatically reversed.
-- ALTER USER "<TAGGED_USER>" UNSET TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_ELIGIBILITY;
-- ALTER USER "<TAGGED_USER>" UNSET TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_COST_CENTER;


-- ============================================================================
-- STEP 4 - PURGE THE DCM PROJECT, THEN DROP THE PROJECT OBJECT
-- ============================================================================
-- DROP DCM PROJECT on its own is NOT a teardown. Per the Snowflake docs,
-- entities a project managed "remain in place as unmanaged resources" after
-- the project is dropped. PURGE runs an empty deployment: it drops every role
-- and tag the project created and revokes its grants. Then drop the project.
--
-- Validated: PURGE dropped all 11 roles and 3 tags and reverted the role
-- grant; the verify queries in STEP 5 then returned no rows.
--
-- Order matters: after STEP 2 (quotas that reference the tags are gone) and
-- STEP 3 (tag values unset while the tag still exists).
EXECUTE DCM PROJECT <CONTROL_DB>.<CONTROL_SCHEMA>.<DCM_PROJECT_NAME> PURGE AS "ai quota teardown";
DROP DCM PROJECT IF EXISTS <CONTROL_DB>.<CONTROL_SCHEMA>.<DCM_PROJECT_NAME>;

-- FALLBACK: only if the project was already dropped without a PURGE, so the
-- roles and tags are now unmanaged. Uncomment and run.
-- DROP ROLE IF EXISTS <ROLE_PREFIX>_EMPLOYEE_COCO;
-- DROP ROLE IF EXISTS <ROLE_PREFIX>_EMPLOYEE_SQL;
-- DROP ROLE IF EXISTS <ROLE_PREFIX>_SERVICE_SQL;
-- DROP ROLE IF EXISTS <ROLE_PREFIX>_PREMIUM_MODELS;
-- DROP ROLE IF EXISTS <ROLE_PREFIX>_PRODUCT_COCO;
-- DROP ROLE IF EXISTS <ROLE_PREFIX>_PRODUCT_SQL;
-- DROP ROLE IF EXISTS <ROLE_PREFIX>_MODEL_STANDARD;
-- DROP ROLE IF EXISTS <ROLE_PREFIX>_MODEL_OPUS;
-- DROP ROLE IF EXISTS <ROLE_PREFIX>_MODEL_WORKLOAD;
-- DROP ROLE IF EXISTS <ROLE_PREFIX>_QUOTA_OPERATOR;
-- DROP ROLE IF EXISTS <ROLE_PREFIX>_COST_AUDITOR;
-- DROP TAG IF EXISTS <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER;
-- DROP TAG IF EXISTS <CONTROL_DB>.<CONTROL_SCHEMA>.AI_ELIGIBILITY;
-- DROP TAG IF EXISTS <CONTROL_DB>.<CONTROL_SCHEMA>.AI_COST_CENTER;


-- ============================================================================
-- STEP 5 - VERIFY THE ACCOUNT IS CLEAN
-- ============================================================================
-- Every one of these must come back empty.
SHOW SNOWFLAKE.CORE.QUOTA INSTANCES IN ACCOUNT;
SHOW DCM PROJECTS IN SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;
SHOW TAGS LIKE 'AI_%' IN SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;
SHOW ROLES LIKE '<ROLE_PREFIX>%';

-- Do NOT run SYSTEM$GET_TAG here. Once the tag object is dropped in STEP 4 the
-- function raises "Tag ... does not exist or not authorized" rather than
-- returning NULL. That error is itself the proof the tag is gone; the readback
-- belongs in STEP 3, before the tag is dropped.
