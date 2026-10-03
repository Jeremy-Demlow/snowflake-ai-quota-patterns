-- ============================================================================
-- 05_escalate.sql - raise a user's allowance when they hit a limit
-- ============================================================================
-- Run ONE option. Read STEP 0 first: the most common mistake is raising the
-- monthly limit when the user is actually blocked on daily, which changes
-- nothing and wastes the on-call cycle.
--
--   Raising MONTHLY does NOT clear a DAILY or WEEKLY block.
--   Each cycle is evaluated independently and releases at its own boundary.
--
--   Option 1  top-up            most escalations. +100, temporary.
--   Option 2  move tier         they are genuinely a power user now.
--   Option 3  raise the tier    the sizing was wrong for everyone.
--   Option 4  wait              the limit was correct.
--
-- Bind the schema, quota names and user before running.
-- ============================================================================

USE ROLE <QUOTA_OWNER_ROLE>;
USE WAREHOUSE <WAREHOUSE>;
USE SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;


-- ============================================================================
-- STEP 0 - DIAGNOSE FIRST. Which cycle is blocking, and on WHICH quota?
-- ============================================================================
-- Start account-wide. A user can be in more than one quota and each one blocks
-- independently, so fixing the wrong quota leaves the block in place.
--
-- This single query answers all four diagnostic questions: WHICH quota, WHICH
-- cycle, how far over they went, and when the block releases on its own.
--
-- ACCOUNT_USAGE lags. In validation a block was in this view within 15 minutes,
-- while GET_ACTIVE_BLOCKS_V2 (below) showed it about a minute after it landed.
-- For a block that just happened, ask the quota.
SELECT ACTION_AT,
       QUOTA_NAME,
       USER_NAME,
       CYCLE,                      -- DAILY / WEEKLY / MONTHLY. Fix THIS cycle.
       ACTION,
       CREDITS,                    -- what they had spent
       PER_USER_LIMIT,             -- against what ceiling
       BLOCKED_UNTIL               -- Option 4 is free if this is soon
FROM SNOWFLAKE.ACCOUNT_USAGE.QUOTA_ACCESS_BLOCK_HISTORY
WHERE ACTION_AT >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY ACTION_AT DESC
LIMIT 50;

-- Then confirm against each quota the user could be in.
CALL QUOTA_AI_STANDARD!GET_ACTIVE_BLOCKS_V2();
CALL QUOTA_AI_INTENSIVE!GET_ACTIVE_BLOCKS_V2();
CALL QUOTA_AI_SERVICE!GET_ACTIVE_BLOCKS_V2();
CALL QUOTA_AI_TOPUP!GET_ACTIVE_BLOCKS_V2();

-- Finalized per-user spend detail. Takes a DATE RANGE, not a user list.
-- The range must fall in the current or prior calendar month; earlier dates
-- return no rows.
CALL QUOTA_AI_STANDARD!GET_SPENDING_DETAILS_BY_USERS('<START_DATE_UTC>', '<END_DATE_UTC>');

-- Was this really a quota block? A model, region or feature-permission error is
-- NOT quota exhaustion and raising a limit will not fix it. A quota block
-- looks like this, and always names the UTC release time:
--   391936 (42501): Your access to AI_COMPLETE is blocked as you have exceeded
--   the usage quota limit defined by your administrator. Your access will be
--   restored automatically after <n> hours ... on <UTC time> or if your quota
--   is changed by your administrator.
CALL QUOTA_AI_STANDARD!GET_ENFORCEMENT_HISTORY('<START_DATE_UTC>', '<END_DATE_UTC>');


-- ============================================================================
-- OPTION 1 - TOP-UP: temporary headroom. THE USUAL ANSWER.
-- ============================================================================
-- Use for "I need a bit more to finish this."
--
-- Moves the user to QUOTA_AI_TOPUP: 100/day, 250/week, 350/month. That is
-- standard plus roughly 100 monthly credits, instead of the 8x over-grant that
-- moving them to intensive would be.
--
-- Measured in validation: unblocked 2 to 4 minutes after the three statements
-- (2m12s and 3m50s in two runs); plan for up to 10. Full procedure, including the weekly sweep that
-- expires it, is in 06_topup.sql PART B. Do not improvise it here - the reversal
-- has a footgun around clearing named lists.
--
--   CALL QUOTA_AI_TOPUP!INCLUDE_USERS(['<USER_NAME>']);
--   CALL QUOTA_AI_STANDARD!EXCLUDE_USERS('USER', ['<USER_NAME>']);
--   ALTER USER "<USER_NAME>" SET TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER = 'topup';


-- ============================================================================
-- OPTION 2 - MOVE TIER: this is their new normal, not an emergency
-- ============================================================================
-- Use when the user is genuinely a power user, or when this is their second
-- top-up in a month. Intensive is 150/day, 600/week, 2000/month.
--
-- A tag key holds one value per user, so this moves them out of standard and
-- into intensive in a single statement.
--
-- Subject to the ~2 hour tag resolution lag, so it is NOT an unblock. If they
-- need to work now, do Option 1 first and move the tier afterwards.
--
-- Accrued spend does NOT reset on a tier move. If they already spent past the
-- new tier's limit this cycle, they stay blocked until the cycle rolls over.
ALTER USER "<USER_NAME>" SET TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER = 'intensive';

SELECT SYSTEM$GET_TAG('<CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER', '"<USER_NAME>"', 'USER') AS tier_now;

-- Need it immediately? A named inclusion overrides tag scope and skips the lag.
-- Both lines are required: quotas evaluate independently, so standard keeps
-- blocking until the user is out of it.
--   CALL QUOTA_AI_INTENSIVE!INCLUDE_USERS(['<USER_NAME>']);
--   CALL QUOTA_AI_STANDARD!EXCLUDE_USERS('USER', ['<USER_NAME>']);
--
-- Once the tag resolves, clean the named lists so the tag alone governs. See
-- 06_topup.sql PART C3 for the safe rebuild procedure - passing an empty array
-- clears the whole list, including the operator safety net.

CALL QUOTA_AI_INTENSIVE!GET_QUOTA_SCOPE();
CALL QUOTA_AI_STANDARD!GET_QUOTA_SCOPE();


-- ============================================================================
-- OPTION 3 - WHOLE TIER IS UNDERSIZED: raise the limit
-- ============================================================================
-- Use when the sizing was wrong for everyone, never for one person.
--
-- THIS AFFECTS EVERY USER IN THE QUOTA, including users added later.
-- Before running, count who is in scope and multiply: users x new daily limit
-- is your new worst-case account exposure for a single day.
CALL QUOTA_AI_STANDARD!GET_USERS();

-- No separate unblock call is needed. After propagation (~5-10 minutes) the
-- pipeline clears blocks for anyone now under the limit and keeps blocks for
-- anyone still over it.
-- Raise ONLY the cycle that STEP 0 showed as blocking.
CALL QUOTA_AI_STANDARD!SET_PER_USER_LIMIT(<NEW_DAILY>,   'DAILY');
-- CALL QUOTA_AI_STANDARD!SET_PER_USER_LIMIT(<NEW_WEEKLY>,  'WEEKLY');
-- CALL QUOTA_AI_STANDARD!SET_PER_USER_LIMIT(<NEW_MONTHLY>, 'MONTHLY');

-- Keep the sizing rule intact: daily < weekly < monthly.
-- Raising daily above weekly makes the DAILY limit unreachable (weekly always
-- trips first) and silently removes your blast-radius control.
CALL QUOTA_AI_STANDARD!GET_CONFIG();

-- Record the new value in quotas.yml, or the next release will revert it.


-- ============================================================================
-- OPTION 4 - DO NOTHING: wait for the cycle boundary
-- ============================================================================
-- Right answer when the limit was correct and the user simply had a big period.
-- Blocks expire automatically with no action:
--   DAILY   -> UTC midnight
--   WEEKLY  -> Monday 00:00 UTC
--   MONTHLY -> the 1st
--
-- Tell the user which boundary applies. "Wait until tomorrow" and "wait until
-- the 1st" are very different answers.
SELECT SYSDATE()                                          AS now_utc,
       DATEADD('day', 1, DATE_TRUNC('day', SYSDATE()))     AS daily_reset_utc,
       DATEADD('week', 1, DATE_TRUNC('week', SYSDATE()))   AS weekly_reset_utc,
       DATEADD('month', 1, DATE_TRUNC('month', SYSDATE())) AS monthly_reset_utc;


-- ============================================================================
-- WHAT NOT TO DO
-- ============================================================================
-- Do NOT disable block enforcement to unblock one person. It unblocks EVERY
-- user in that quota within ~5-10 minutes and removes the control entirely:
--   SET_BLOCK_ENFORCEMENT_ENABLED(FALSE, ...)   <- not an escalation path
--
-- Do NOT drop and recreate the quota. Metering history and scope are lost and
-- the block returns as soon as spend is re-evaluated.
--
-- Do NOT exclude a user from all quotas as a way to give them more. That is not
-- a higher limit, it is no limit, and it is invisible in the tier reporting.
--
-- Do NOT clear a named list with an empty array to reverse one exception.
-- EXCLUDE_USERS('USER', []) and INCLUDE_USERS([]) clear the ENTIRE list. If
-- that removes the operator safety net on QUOTA_AI_STANDARD. Rebuild the list
-- deliberately; see 06_topup.sql PART C3.
--
-- Do NOT widen model grants to work around a quota. A quota is a spend control;
-- model access is a separate permission. A few long-context Opus-class calls
-- can exceed a standard user's monthly limit before the quota evaluates. No
-- quota prevents a single expensive query; only model RBAC does.
