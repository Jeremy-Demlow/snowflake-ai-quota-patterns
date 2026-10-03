-- ============================================================================
-- 06_topup.sql - give ONE user temporary headroom and keep them working
-- ============================================================================
-- THE PROBLEM THIS SOLVES
--   A user hits the standard limit and needs a bit more to finish their work.
--   Snowflake does not allow a per-user override inside one quota:
--
--     "You cannot set different limits for different users within the same
--      quota. All users share the same per-user limits."
--
--   So "+100 credits for Bob" is impossible as a limit change. The documented
--   pattern is to move Bob to a quota with a higher limit. Moving him into the
--   intensive tier works, but takes him from 50/day 250/month to 150/day
--   2,000/month: an 8x monthly over-grant to solve "I need a bit more today."
--
--   QUOTA_AI_TOPUP is sized deliberately small: standard plus roughly 100
--   monthly credits, and double the daily allowance.
--
--       STANDARD          TOPUP
--       50/day            100/day      +50 today
--       120/week          250/week
--       250/month         350/month    +100 this month
--
--   THE LIMITS ARE CEILINGS, NOT INCREMENTS
--   A top-up does not add 100 credits to what the user already has. It is a
--   second, higher ceiling on the SAME running total. Spend is counted once per
--   cycle, and whichever quota the user is in judges it against its own limit.
--     - A user at 250 of 250 monthly moves to top-up and sits at 250 of 350:
--       100 of headroom.
--     - A user at 240 of 250 moves and sits at 240 of 350: 110 of headroom.
--     - Nothing resets on the move. Validated: a user blocked at 1.26 of a 1.0
--       daily limit was moved to a 3.0 top-up and blocked again at 3.43.
--   Every member of this quota shares the SAME limits. Giving Alice +100 and Bob
--   +300 needs a second top-up quota with its own ceiling; one quota cannot do both.
--   Only the people you add by name are in it, so topping up one user leaves
--   everyone else in standard untouched. Validated: a second user over the same
--   limit stayed blocked for the whole time the first was topped up.
--
-- ----------------------------------------------------------------------------
-- WHY THIS QUOTA IS EMPTY WHEN YOU CREATE IT
-- ----------------------------------------------------------------------------
--   A new quota defaults to ALL USERS. That is the opposite of what a top-up
--   quota needs. We narrow it by scoping to AI_SPEND_TIER = 'topup', a value no
--   user carries by default. The tag scope therefore resolves to nobody, and the
--   only members are the names you add explicitly.
--
--   'topup' is declared in dcm/manifest.yml -> spend_tiers so DCM deploys it as
--   an allowed tag value, and it is in 04_tier_standard.sql's tag exclusion list
--   so a tagged user leaves the standard quota automatically.
--
-- Bind the schema, quota names, limits and emails before running.
-- ============================================================================

USE ROLE <QUOTA_OWNER_ROLE>;
USE WAREHOUSE <WAREHOUSE>;
USE SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;


-- ============================================================================
-- PART A - ONE-TIME SETUP. Run once, at deployment.
-- ============================================================================

-- --- A1. Create the quota ----------------------------------------------------
CREATE SNOWFLAKE.CORE.QUOTA IF NOT EXISTS QUOTA_AI_TOPUP();

-- --- A2. Narrow the scope to a tag value nobody has --------------------------
-- This is the step that makes the quota empty instead of account-wide.
-- SET_USER_TAGS is atomic and idempotent; it replaces any previous tag scope.
CALL QUOTA_AI_TOPUP!SET_USER_TAGS(
    [[(SELECT SYSTEM$REFERENCE('TAG', '<CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER', 'SESSION', 'APPLYBUDGET')), 'topup']],
    'UNION'
);

-- --- A3. Same monitored domains as the standard tier ------------------------
-- These MUST match 04_tier_standard.sql. If topup monitors fewer domains than
-- standard, moving a user here silently stops governing the missing ones.
CALL QUOTA_AI_TOPUP!ADD_SHARED_RESOURCE('AI FUNCTION');
CALL QUOTA_AI_TOPUP!ADD_SHARED_RESOURCE('CORTEX CODE');
CALL QUOTA_AI_TOPUP!ADD_SHARED_RESOURCE('CORTEX AGENT');
CALL QUOTA_AI_TOPUP!ADD_SHARED_RESOURCE('SNOWFLAKE INTELLIGENCE');

-- --- A4. Limits: DAILY FIRST ------------------------------------------------
CALL QUOTA_AI_TOPUP!SET_PER_USER_LIMIT(100, 'DAILY');
CALL QUOTA_AI_TOPUP!SET_PER_USER_LIMIT(250, 'WEEKLY');
CALL QUOTA_AI_TOPUP!SET_PER_USER_LIMIT(350, 'MONTHLY');

-- --- A5. Notifications ------------------------------------------------------
-- Tighter thresholds than standard on purpose. A user who exhausts a top-up
-- needs a tier review, not a second top-up.
CALL QUOTA_AI_TOPUP!SET_ADMIN_EMAILS('<QUOTA_ADMIN_EMAILS>');
CALL QUOTA_AI_TOPUP!ADD_NOTIFICATION_THRESHOLD(80, 'ACTUAL', TRUE, 'MONTHLY');
CALL QUOTA_AI_TOPUP!ADD_NOTIFICATION_THRESHOLD(90, 'ACTUAL', TRUE, 'DAILY');

-- --- A6. Verify it is EMPTY -------------------------------------------------
-- GET_USERS() must return zero rows. If it returns your whole account, step A2
-- did not take effect and enabling enforcement would apply a 100-credit daily
-- limit to everyone.
--
-- Validated in a Snowflake lab account: GET_USERS returned "No data" after A2,
-- confirming that scoping to an unused tag value produces an empty quota
-- rather than the all-users default.
CALL QUOTA_AI_TOPUP!GET_QUOTA_SCOPE();
CALL QUOTA_AI_TOPUP!GET_USERS();
CALL QUOTA_AI_TOPUP!GET_CONFIG();

-- --- A7. Blocking is enabled by 07_enable_blocking.sql, not here -------------
-- Same reason as the tier files: this quota starts as ALL USERS and A2 narrows
-- it. Enabling blocking before A2 propagates would briefly apply 100/day to
-- the whole account.


-- ============================================================================
-- PART B - GRANT A TOP-UP. This is what the help desk runs.
-- ============================================================================
-- Diagnose first with 05_escalate.sql STEP 0. If the user is blocked on WEEKLY
-- or MONTHLY, a top-up helps. If they are blocked on DAILY and it is 23:30 UTC,
-- waiting 30 minutes is the better answer.
--
-- Three statements, all required. Measured in validation: the block cleared
-- 2 minutes 12 seconds after they ran in one run and 3 minutes 50 seconds in
-- another (the quota's own UNBLOCKED record). The user's next AI_COMPLETE call
-- succeeded by 4 minutes 39 seconds at the latest. Documented propagation is up
-- to ~5-10 minutes; tell the user 10.

-- B1. Add them to the top-up quota. A named inclusion takes precedence over tag
--     scope and does NOT wait on the ~2 hour tag resolution lag.
CALL QUOTA_AI_TOPUP!INCLUDE_USERS(['<USER_NAME>']);

-- B2. Remove them from standard. WITHOUT THIS THEY STAY BLOCKED. Quotas are
--     evaluated independently, so standard's 50/day keeps blocking regardless
--     of what topup allows.
CALL QUOTA_AI_STANDARD!EXCLUDE_USERS('USER', ['<USER_NAME>']);

-- B3. Set the tag so the steady state agrees with the named lists. Once the tag
--     resolves (~2h), membership is correct from the tag alone, which is what
--     makes the sweep in PART C safe.
ALTER USER "<USER_NAME>" SET TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER = 'topup';

-- B4. Confirm. The user should appear in TOPUP's included_users and in
--     STANDARD's excluded_users.
--
--     USE GET_QUOTA_SCOPE, NOT GET_USERS, TO CONFIRM A TOP-UP.
--     Validated in a Snowflake lab account: after INCLUDE_USERS, GET_QUOTA_SCOPE showed the
--     user in included_users immediately, while GET_USERS still returned no
--     rows. GET_USERS resolves membership through TAG_REFERENCES and lags.
--     A help desk that confirms with GET_USERS will wrongly conclude the
--     top-up failed and grant a second one.
CALL QUOTA_AI_TOPUP!GET_QUOTA_SCOPE();
CALL QUOTA_AI_STANDARD!GET_QUOTA_SCOPE();
CALL QUOTA_AI_TOPUP!GET_ACTIVE_BLOCKS_V2();

-- Accrued spend does NOT reset. If the user already spent 260 credits this
-- month, a 350 monthly limit leaves them 90, not 350. Validated: a user
-- blocked at 1.26 of a 1-credit daily limit was topped up to 3/day and was
-- blocked again at 3.43 - the day's earlier spend counted against the top-up.


-- ============================================================================
-- PART C - EXPIRE IT. Run weekly. Without this, top-ups are permanent.
-- ============================================================================
-- INCLUDE_USERS and EXCLUDE_USERS ACCUMULATE and have NO TTL. Nothing in
-- Snowflake expires a top-up. This review is the only thing that does.

-- --- C1. Who currently has a top-up, and since when? ------------------------
CALL QUOTA_AI_TOPUP!GET_QUOTA_SCOPE();

-- Tag-based view with age. TAG_REFERENCES lags up to ~2 hours, so a top-up
-- granted minutes ago may not appear here yet; GET_QUOTA_SCOPE above is the
-- immediate read.
SELECT u.NAME AS user_name,
       t.TAG_VALUE AS tier,
       'Review: still needed, or move tier, or return to standard' AS action
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS u
JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
  ON t.OBJECT_ID = u.USER_ID
 AND t.DOMAIN = 'USER'
 AND t.TAG_NAME = 'AI_SPEND_TIER'
 AND t.TAG_DATABASE = '<CONTROL_DB>'
 AND t.TAG_SCHEMA = '<CONTROL_SCHEMA>'
 AND t.TAG_VALUE = 'topup'
WHERE u.DELETED_ON IS NULL
ORDER BY user_name;

-- --- C2. Did they actually use it? ------------------------------------------
-- Dates must fall in the current or prior calendar month; earlier ranges return
-- nothing. A user who never approached 250 did not need the top-up.
CALL QUOTA_AI_TOPUP!GET_SPENDING_DETAILS_BY_USERS('<START_DATE_UTC>', '<END_DATE_UTC>');

-- --- C3. Return one user to standard ----------------------------------------
--
-- !! SPEND DOES NOT RESET WHEN YOU RETURN A USER !!
-- Standard judges the same running total against its lower ceiling. Validated:
-- after this reversal the user kept working for about 5 minutes, then standard
-- blocked them again at 2.17 against a 1.0 daily limit (5 minutes 8 seconds
-- after the sweep). A user who spent 300 this month goes back to a 250 limit
-- and is blocked until the 1st.
--   - Run C2 first. Only return users whose spend is under standard's limits.
--   - Sweep right after the monthly reset (1st, 00:00 UTC), when counters are
--     near zero. A weekly sweep mid-month blocks anyone still above standard.
--
-- Step 1: drop the tag. This alone returns them to standard once it resolves,
-- because standard excludes the 'topup' tag and topup scopes to it.
ALTER USER "<USER_NAME>" UNSET TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER;

-- Step 2: clean the named lists, which still override the tag.
--
-- !! READ THIS BEFORE CLEARING A LIST !!
-- There is no "remove one name" method. Passing an empty array clears the
-- ENTIRE list for that quota. Validated: EXCLUDE_USERS('USER', []) on a list of
-- two names reported "cleared 2 user exclude(s)" and GET_QUOTA_SCOPE then showed
-- an empty list, operator included. Restoring the names 3 seconds later worked;
-- the clear-and-re-add below did keep the operator and remove only the one user. If QUOTA_AI_STANDARD's excluded_users also
-- holds <OPERATOR_USER> as a deliberate safety net (04_tier_standard.sql step 2b), so
-- a blind EXCLUDE_USERS('USER', []) would put the operator inside the
-- 250-credit limit.
--
-- Rebuild deliberately instead:
--   1. CALL QUOTA_AI_STANDARD!GET_QUOTA_SCOPE();   -- record excluded_users
--   2. Remove only the expiring user from that list on paper
--   3. Clear, then re-add the remainder in one call:
--        CALL QUOTA_AI_STANDARD!EXCLUDE_USERS('USER', []);
--        CALL QUOTA_AI_STANDARD!EXCLUDE_USERS('USER', ['<OPERATOR_USER>', '<OTHERS>']);
--   4. Same two-step for QUOTA_AI_TOPUP!INCLUDE_USERS
--
-- Do the same for the top-up list:
--   CALL QUOTA_AI_TOPUP!INCLUDE_USERS([]);
--   CALL QUOTA_AI_TOPUP!INCLUDE_USERS(['<REMAINING_TOPUP_USERS>']);

-- --- C4. Confirm the reversal -----------------------------------------------
CALL QUOTA_AI_STANDARD!GET_QUOTA_SCOPE();
CALL QUOTA_AI_TOPUP!GET_QUOTA_SCOPE();
SELECT SYSTEM$GET_TAG('<CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER', '"<USER_NAME>"', 'USER') AS tier_now;


-- ============================================================================
-- WHEN A TOP-UP IS THE WRONG ANSWER
-- ============================================================================
-- Second top-up in a month      -> their tier is wrong. Move to intensive.
-- Whole team needs one          -> the tier is undersized. 05_escalate Option 3.
-- A service account needs one   -> it belongs in 'service', not 'topup'.
-- One query burned the limit    -> a model RBAC problem, not a spend problem.
--                                  Restrict Opus-class models by role.
-- Blocked on DAILY late in day  -> wait for UTC midnight.


-- ============================================================================
-- AUTO-EXPIRY: registered, NOT observed firing
-- ============================================================================
-- A cycle-start action runs a stored procedure on the 1st of each UTC month, on
-- the monthly cycle only. Attached to this quota it could end top-ups when the
-- counters reset, so a top-up means "this month" without a weekly sweep.
--
-- What was verified: the registration below succeeded, GET_CYCLE_START_ACTION
-- returned it, and the example procedure, run by hand, cleared the include list.
-- What was NOT verified: that it fires on the 1st. That cannot be forced.
-- The example clears ONLY the top-up include list. A complete version must also
-- remove each user from standard's exclude list without wiping the operator, and
-- unset their tag. That is not built.
--
-- Registration needs USAGE on the database and schema for the SNOWFLAKE
-- application, as well as on the procedure. Without them it fails with
-- INVALID_PROCEDURE_OR_MISSING_PERMISSIONS.
--
-- GRANT USAGE ON DATABASE <CONTROL_DB> TO APPLICATION SNOWFLAKE;
-- GRANT USAGE ON SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA> TO APPLICATION SNOWFLAKE;
-- CREATE OR REPLACE PROCEDURE <CONTROL_DB>.<CONTROL_SCHEMA>.EXPIRE_TOPUPS()
--   RETURNS VARCHAR LANGUAGE SQL EXECUTE AS OWNER AS
--   $$ BEGIN CALL QUOTA_AI_TOPUP!INCLUDE_USERS([]); RETURN 'cleared'; END; $$;
-- GRANT USAGE ON PROCEDURE <CONTROL_DB>.<CONTROL_SCHEMA>.EXPIRE_TOPUPS()
--   TO APPLICATION SNOWFLAKE;
-- CALL QUOTA_AI_TOPUP!SET_CYCLE_START_ACTION(
--   SYSTEM$REFERENCE('PROCEDURE', '<CONTROL_DB>.<CONTROL_SCHEMA>.EXPIRE_TOPUPS()'), []);
-- CALL QUOTA_AI_TOPUP!GET_CYCLE_START_ACTION();
