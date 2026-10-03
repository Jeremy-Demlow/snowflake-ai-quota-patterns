-- ============================================================================
-- 01_assign_tiers.sql - put users INTO a tier. Run BEFORE creating any quota.
-- ============================================================================
-- THIS IS THE STEP THAT ANSWERS "how does anyone become intensive or standard?"
--
-- The quota files (02, 03, 04) only define WHICH TAG VALUE maps to which quota.
-- They do not assign anything. This file is where a user actually gets a tier.
--
--   02_tier_service.sql    scopes to  AI_SPEND_TIER = 'service'
--   03_tier_intensive.sql  scopes to  AI_SPEND_TIER = 'intensive'
--   04_tier_standard.sql   scopes to  everyone EXCEPT those two tags
--
-- So 'standard' is never applied as a tag. It is the absence of the other two.
-- That is deliberate: a user created next month lands in standard with no
-- action, instead of being ungoverned until somebody remembers to tag them.
--
-- ----------------------------------------------------------------------------
-- WHY THIS RUNS FIRST
-- ----------------------------------------------------------------------------
-- A brand-new quota defaults to ALL USERS. If you create the standard quota
-- before tagging your heavy users, they are briefly inside the low limit and
-- can be blocked. Tag first, then create quotas, and the exclusions are already
-- correct the moment the standard quota exists.
--
--   tag heavy users  ->  create service  ->  create intensive  ->  create standard
--
-- ----------------------------------------------------------------------------
-- PICK ONE WRITER. DO NOT USE BOTH.
-- ----------------------------------------------------------------------------
-- This file is the SIMPLE path: direct tagging. For steady state, prefer SCIM:
-- your IdP can set AI_SPEND_TIER through the snowflakeTags attribute at
-- provisioning time, so no SQL is needed per user.
--
-- Whatever you choose, use ONE writer for this tag. Two writers (for example
-- SCIM and this file) against the same user produce drift that no query here
-- can attribute. Choose, and record the choice.
--
-- ----------------------------------------------------------------------------
-- Membership mirrors the members block in quotas.yml for your target.
-- ============================================================================

USE ROLE <QUOTA_OWNER_ROLE>;
USE WAREHOUSE <WAREHOUSE>;
USE SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;

-- --- 1. Confirm the tag exists and knows its allowed values ------------------
-- Deployed by DCM from sources/definitions/tags.sql. If ALLOWED_VALUES is empty
-- or missing a tier, stop: a typo would otherwise create a silent fourth tier.
SHOW TAGS LIKE 'AI_SPEND_TIER' IN SCHEMA <CONTROL_DB>.<CONTROL_SCHEMA>;

-- --- 2. Confirm the identity before tagging ---------------------------------
-- Check the user exists, is not disabled, and note the type. A SERVICE type
-- almost always belongs in 'service', not 'intensive'.
SHOW USERS LIKE '<USER_NAME>';

-- --- 3. Assign the tier -----------------------------------------------------
-- Example: the quota operator goes to 'intensive' so the standard tier cannot
-- block their own work. Also exclude them BY NAME in 04_tier_standard.sql
-- step 2b: a tag change takes up to ~2 hours to reach quota membership.
ALTER USER "<USER_NAME>" SET TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER = 'intensive';

-- Batch pipelines and service identities go to 'service' instead:
-- ALTER USER "<SERVICE_USER>" SET TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER = 'service';

-- Everyone else: DO NOTHING. No tag means standard, which is the default tier.

-- --- 4. Read the tag back ---------------------------------------------------
-- SYSTEM$GET_TAG reads current state directly, so it is immediate. It does NOT
-- have the roughly two-hour lag that quota membership resolution has.
SELECT SYSTEM$GET_TAG('<CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER', '"<USER_NAME>"', 'USER') AS tier_now;

-- --- 5. See every tier assignment in the account ----------------------------
-- TAG_REFERENCES lags up to about two hours, so a tag set moments ago may not
-- appear yet. SYSTEM$GET_TAG above is the authoritative immediate read.
SELECT u.NAME AS user_name,
       u.TYPE AS user_type,
       COALESCE(t.TAG_VALUE, 'standard (no tag = default tier)') AS tier
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS u
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
       ON t.OBJECT_ID = u.USER_ID
      AND t.DOMAIN = 'USER'
      AND t.TAG_NAME = 'AI_SPEND_TIER'
      AND t.TAG_DATABASE = '<CONTROL_DB>'
      AND t.TAG_SCHEMA = '<CONTROL_SCHEMA>'
WHERE u.DELETED_ON IS NULL
  AND NOT u.DISABLED
  AND (t.TAG_VALUE IS NOT NULL OR u.TYPE = 'PERSON')
ORDER BY tier, user_name;

-- --- 6. Reversing a tier ----------------------------------------------------
-- UNSET returns the user to the standard tier, because standard is the absence
-- of a tag. It does NOT remove them from governance.
-- ALTER USER "<USER_NAME>" UNSET TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER;
--
-- Accrued spend does NOT reset when a tier changes. Moving to a lower tier
-- mid-cycle can block immediately if spend already exceeds the new limit.
-- Tag changes take roughly two hours to affect quota membership. For an
-- immediate move, use named inclusion (06_topup.sql PART B pattern).
