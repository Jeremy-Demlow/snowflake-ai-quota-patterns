-- ============================================================================
-- 07_enable_blocking.sql - turn the quotas from observe-only into enforcing
-- ============================================================================
-- Run this LAST, as its own deployment step, at least 10 minutes after the
-- final scope change in 02-06. Until this runs, every quota measures spend and
-- sends notifications but blocks nobody.
--
-- WHY THIS IS A SEPARATE FILE
--   Every quota is created with the default ALL USERS scope and narrowed a few
--   statements later (SET_USER_TAGS, EXCLUDE_USERS). Scope changes take ~5-10
--   minutes to propagate to enforcement.
--
--   In a Snowflake lab account the tier files originally enabled blocking in the
--   same pass that created each quota. The operator was blocked by the standard
--   quota on DAILY and MONTHLY within minutes, even though GET_QUOTA_SCOPE
--   already listed them as excluded by tag AND by name. QUOTA_ACCESS_BLOCK_HISTORY
--   shows the block, then an UNBLOCKED 42 seconds later with no change made:
--   enforcement's first evaluation used the pre-exclusion (all users) scope.
--
--   Re-validated with this file: the gate below stopped a `snow sql -f` run on
--   3-minute-old quotas (error -20001, exit code 1, nothing enabled). At 12
--   minutes it enabled all four, and the operator was never blocked across
--   27 minutes of enforcement while a test user was blocked and topped up.
--
--   A "STOP HERE" comment does not protect anyone when a file runs as
--   `snow sql -f`. This file enforces the wait with a gate that raises.
--
-- PROPAGATION IS NOT THE SAME FOR TAGS AND NAMES
--   Named INCLUDE_USERS / EXCLUDE_USERS: ~5-10 minutes.
--   Tag-based scope: resolves through TAG_REFERENCES, which can lag ~2 hours.
--   Anyone who must never be blocked (the quota operator, break-glass admins)
--   should be excluded BY NAME in 04_tier_standard.sql step 2b, not only by tag.
--
-- ORDER
--   Enable the narrow quotas first and standard LAST. Standard covers everyone
--   by default and is the one that can lock out an operator; if something is
--   wrong you want to find it before that switch, not after.
-- ============================================================================

USE ROLE <QUOTA_OWNER_ROLE>;
USE WAREHOUSE <WAREHOUSE>;
USE SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;


-- ============================================================================
-- GATE 1 - the quotas are old enough for their scope to have propagated
-- ============================================================================
-- Fails the run if any package quota was created less than 10 minutes ago.
-- A later scope change restarts the clock and this gate cannot see that; if
-- you changed scope since creation, wait 10 minutes from that change too.
SHOW SNOWFLAKE.CORE.QUOTA INSTANCES IN SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;

SELECT "name"                                            AS quota_name,
       "created_on"                                      AS created_on,
       DATEDIFF('minute', "created_on", CURRENT_TIMESTAMP()) AS minutes_old,
       IFF(DATEDIFF('minute', "created_on", CURRENT_TIMESTAMP()) >= 10,
           'ok', 'TOO NEW - wait') AS verdict
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" LIKE 'QUOTA_AI_%'
ORDER BY quota_name;

EXECUTE IMMEDIATE $$
DECLARE
  too_new INTEGER;
  too_new_error EXCEPTION (-20001, 'A QUOTA_AI_ quota is less than 10 minutes old. Wait for scope to propagate, then re-run 07_enable_blocking.sql.');
BEGIN
  SHOW SNOWFLAKE.CORE.QUOTA INSTANCES IN SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;
  SELECT COUNT(*) INTO :too_new
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
  WHERE "name" LIKE 'QUOTA_AI_%'
    AND DATEDIFF('minute', "created_on", CURRENT_TIMESTAMP()) < 10;
  IF (too_new > 0) THEN
    RAISE too_new_error;
  END IF;
  RETURN 'Gate 1 passed: every QUOTA_AI_ quota is at least 10 minutes old.';
END;
$$;


-- ============================================================================
-- GATE 2 - read every scope. The protected people must be where you expect.
-- ============================================================================
--   QUOTA_AI_STANDARD   excluded_users contains <OPERATOR_USER>
--                       excluded tags: intensive, service, topup
--   QUOTA_AI_INTENSIVE  tag intensive
--   QUOTA_AI_SERVICE    tag service
--   QUOTA_AI_TOPUP      tag topup, included_users = only granted top-ups
CALL QUOTA_AI_SERVICE!GET_QUOTA_SCOPE();
CALL QUOTA_AI_INTENSIVE!GET_QUOTA_SCOPE();
CALL QUOTA_AI_TOPUP!GET_QUOTA_SCOPE();
CALL QUOTA_AI_STANDARD!GET_QUOTA_SCOPE();


-- ============================================================================
-- STEP 1 - enable the narrow quotas
-- ============================================================================
-- Second argument TRUE notifies the end user when they are blocked.
CALL QUOTA_AI_SERVICE!SET_BLOCK_ENFORCEMENT_ENABLED(TRUE, TRUE);
CALL QUOTA_AI_INTENSIVE!SET_BLOCK_ENFORCEMENT_ENABLED(TRUE, TRUE);
CALL QUOTA_AI_TOPUP!SET_BLOCK_ENFORCEMENT_ENABLED(TRUE, TRUE);


-- ============================================================================
-- STEP 2 - enable standard, last
-- ============================================================================
CALL QUOTA_AI_STANDARD!SET_BLOCK_ENFORCEMENT_ENABLED(TRUE, TRUE);


-- ============================================================================
-- STEP 3 - confirm the operator is not blocked
-- ============================================================================
-- Blocks can appear a few minutes after enabling. Re-run this after ~10 minutes.
-- If <OPERATOR_USER> appears in standard's active blocks, disable standard
-- immediately (it releases within ~5-10 minutes), fix the scope, and wait again:
--   CALL QUOTA_AI_STANDARD!SET_BLOCK_ENFORCEMENT_ENABLED(FALSE, FALSE);
CALL QUOTA_AI_STANDARD!GET_ACTIVE_BLOCKS_V2();
CALL QUOTA_AI_INTENSIVE!GET_ACTIVE_BLOCKS_V2();
CALL QUOTA_AI_SERVICE!GET_ACTIVE_BLOCKS_V2();
CALL QUOTA_AI_TOPUP!GET_ACTIVE_BLOCKS_V2();

CALL QUOTA_AI_STANDARD!GET_CONFIG();
