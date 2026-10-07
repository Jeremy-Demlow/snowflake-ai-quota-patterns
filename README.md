# Snowflake AI Quota Patterns

Per-user spend limits for Snowflake AI (Snowflake CoCo, formerly Cortex Code; Cortex Agents; Snowflake CoWork, formerly Snowflake Intelligence; AI functions; and the AI Gateway, in Preview), built entirely from native Snowflake controls: tags, per-user quotas and, optionally, a DCM project for roles. The validation below exercised AI functions; the other domains are documented as enforceable but were not separately tested here.

Two questions, answered by two different mechanisms:

- **Who may invoke AI, and with which models?** Role-based access and model application roles.
- **How much may each person spend?** `SNOWFLAKE.CORE.QUOTA` objects, one per spend tier.

It contains no scheduled tasks, polling warehouses or customer-written enforcement code. Snowflake enforces the limits.

> **Legal notice.** A community example, not an official or supported Snowflake product. Provided as is, without warranty. These scripts can block users, including administrators, from AI features; test in a non-production account first. See [LEGAL_NOTICE.md](LEGAL_NOTICE.md).

---

## The three problems this solves

1. **One quota has one limit for every user in it.** Snowflake has no per-user override. "Alice is a power user" and "Bob needs 100 more credits today" both mean *moving the user to a different quota*. This repo gives you the tiers to move them between.
2. **A new quota covers every user in the account.** That's the right default for a standard tier, because a user created next month is governed on day one. It's the wrong default for everything else. The scripts carve out the other tiers by tag, and they build an empty top-up quota by scoping it to a tag value nobody has.
3. **Enabling blocking too early locks out the people you excluded.** Exclusions take minutes to propagate. [quota/07_enable_blocking.sql](quota/07_enable_blocking.sql) is the only file that turns blocking on, and it refuses to run until the quotas are old enough.

---

## What is actually being built

```
LAYER 1   CAPABILITY - can this person invoke AI, and with which models
OWNER: dcm/ (optional). Declarative, versioned, re-deployable.
------------------------------------------------------------------------
  snow dcm deploy --target DEV
          |
          v
  dcm/sources/definitions/
          |
          +-- tags.sql                 AI_SPEND_TIER    quota scoping key
          |                            AI_ELIGIBILITY   IAM metadata only
          |                            AI_COST_CENTER   showback
          |
          +-- access.sql               11 roles, wired:
          |                              _EMPLOYEE_COCO  = PRODUCT_COCO + MODEL_STANDARD
          |                              _EMPLOYEE_SQL   = PRODUCT_SQL  + MODEL_STANDARD
          |                              _SERVICE_SQL    = PRODUCT_SQL  + MODEL_WORKLOAD
          |                              _PREMIUM_MODELS = MODEL_OPUS
          |
          +-- model_grants.sql         which models each role may call

  Answers: CAN they use AI.        Does NOT answer: how much.
  Skip this layer and you still need the one tag; see "Without DCM".


LAYER 2   SPEND - how much they may spend
OWNER: quota/. Imperative. DCM CANNOT own this.
------------------------------------------------------------------------
  There is no DEFINE SNOWFLAKE.CORE.QUOTA. Quota configuration is method
  calls on a live object, so it lives in run-once scripts driven by a
  single config file.

  quotas.yml          limits, domains, thresholds, tier membership
          |
          v
  quota/00_size_limits.sql      measure real usage, choose numbers
  quota/01_assign_tiers.sql     ALTER USER SET TAG AI_SPEND_TIER = ...
  quota/02_tier_service.sql     |
  quota/03_tier_intensive.sql   |  one quota object per tier,
  quota/04_tier_standard.sql    |  created observe-only
  quota/06_topup.sql            temporary headroom, keep working
  quota/07_enable_blocking.sql  switch observe-only -> enforcing. LAST.
  quota/05_escalate.sql         diagnose a block, then choose a path
  quota/99_teardown.sql         remove everything (non-production)

                    AI_SPEND_TIER tag value
                              |
      +---------+-------------+-------------+
      |         |             |             |
  'service' 'intensive'    'topup'      (no tag)
      |         |             |             |
      v         v             v             v
   SERVICE   INTENSIVE      TOPUP       STANDARD
   300/day   150/day        100/day     50/day
   1000/wk   600/wk         250/wk      120/wk
   3000/mo   2000/mo        350/mo      250/mo
   pipelines power users   TEMPORARY    DEFAULT
                          named users   nobody escapes

  Example numbers. Size your own with 00_size_limits.sql.
  Enforcement is Snowflake-managed. Blocks clear at the cycle boundary.


LAYER 3   ASSURANCE - does the account match what you intended
OWNER: audit.sql
------------------------------------------------------------------------
  audit.sql      roster, exceptions, and AI spend by identities holding
                 no package role (proves PUBLIC's access is really gone)


RUNTIME - what happens on each AI request
------------------------------------------------------------------------
  AI request
      |
      +-- Layer 1: role + model grant?      no -> authorization error
      |
      +-- Layer 2: under every cycle limit? no -> quota-exhausted error
      |
      v
  allowed
```

**Adding or removing a user never requires recreating a quota.** Tier membership is a tag or a named list. Quotas are shared policy.

---

## How to deploy it

```
STEP 0   MEASURE FIRST                                    read-only
------------------------------------------------------------------------
  quota/00_size_limits.sql        120 days of your own usage
      |                             - credits per user per domain
      |                             - p95 and worst single day
      |                             - WOULD BLOCK ON DAILY flags
      |                             - expensive-model concentration
      v
  copy quotas.example.yml -> quotas.yml, write your numbers in.
  Do not deploy guessed limits. A guessed daily limit either blocks real
  work or controls nothing.


STEP 1   CREATE THE TAG (and optionally the roles)
------------------------------------------------------------------------
  with DCM:     snow dcm plan / deploy  from dcm/
  without DCM:  CREATE TAG ... AI_SPEND_TIER   (see "Without DCM" below)
      v
  Nobody is enrolled yet.


STEP 2   TIER THE HEAVY USERS
------------------------------------------------------------------------
  quota/01_assign_tiers.sql       ALTER USER ... SET TAG
      |
      |   MUST run before any quota exists. A new quota defaults to ALL
      |   USERS, so creating standard first puts your heaviest users
      |   inside the low limit while their tags propagate.
      v
  pipelines -> 'service'   power users -> 'intensive'   everyone else: no tag


STEP 3   CREATE THE QUOTAS, OBSERVE-ONLY
------------------------------------------------------------------------
  quota/02_tier_service.sql       carve out pipelines
  quota/03_tier_intensive.sql     carve out power users
  quota/04_tier_standard.sql      all users MINUS those tags, operator
                                  excluded by name
  quota/06_topup.sql PART A       empty by default, for escalations
      |
      |   Daily limit FIRST, then weekly, then monthly, so the
      |   blast-radius control exists before the budget control.
      |   NONE of these files enables blocking. The quotas measure and
      |   notify, and block nobody.
      v
  CALL <quota>!GET_QUOTA_SCOPE()


STEP 4   TURN ON BLOCKING, SEPARATELY
------------------------------------------------------------------------
  wait >= 10 minutes after the last scope change
      |
      v
  quota/07_enable_blocking.sql
      |   gate: raises if any QUOTA_AI_ quota is < 10 minutes old
      |   GET_QUOTA_SCOPE on all four
      |   enable service, intensive, topup ... then standard LAST
      v
  GET_ACTIVE_BLOCKS_V2 on standard: the operator must NOT appear


STEP 5   ENROLL USERS
------------------------------------------------------------------------
  IdP group -> SCIM -> role grant + snowflakeTags (AI_SPEND_TIER)
      v
  audit.sql                        confirm intent matches the account


STEP 6   REMOVE THE OLD BLANKET ACCESS
------------------------------------------------------------------------
  REVOKE DATABASE ROLE SNOWFLAKE.CORTEX_USER FROM ROLE PUBLIC;
  REVOKE APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-ALL" FROM ROLE PUBLIC;
      |
      |   Until PUBLIC's inherited AI access is revoked, Layer 1
      |   restricts nothing. Quotas (Layer 2) work either way.
      v
  audit.sql QUERY 3: only identities you can explain remain
```

---

## Day in the life

```
EVENT 1   new hire needs CoCo                            most changes
------------------------------------------------------------------------
  IdP: add to "AI Users" group
         |
         v
  SCIM pushes to Snowflake
    - grants _EMPLOYEE_COCO
    - no tier tag, so they land in STANDARD automatically
         |
         v
  governed. zero SQL. Evidence = the IdP's own log.


EVENT 2   "I am blocked, I need more credits"       common escalation
------------------------------------------------------------------------
  quota/05_escalate.sql  STEP 0 FIRST - which cycle, which quota?
      |
      |   A user can be in more than one quota and each blocks
      |   independently. Raising MONTHLY does NOT clear a DAILY block.
      v
  then pick ONE:

  Option 1  quota/06_topup.sql        <-- the usual answer
              CALL QUOTA_AI_TOPUP!INCLUDE_USERS(['BOB']);
              CALL QUOTA_AI_STANDARD!EXCLUDE_USERS('USER',['BOB']);
              +100 credits this month, not +1,750.
              Both lines required - quotas evaluate independently.
              Measured: unblocked in 2-4 min. Tell them 10.

  Option 2  move their tier           this is their new normal
              ALTER USER BOB SET TAG ... = 'intensive';
              up to ~2h lag. Not an unblock.

  Option 3  raise the whole tier      the sizing was wrong for everyone

  Option 4  wait for the boundary     the limit was correct
              DAILY -> 00:00 UTC, WEEKLY -> Mon 00:00 UTC, MONTHLY -> 1st


EVENT 3   someone wants Opus                        rare, high stakes
------------------------------------------------------------------------
  GRANT ROLE <prefix>_PREMIUM_MODELS TO USER BOB;
      |
      |   A quota is evaluated minutes after spend. A few long-context
      |   calls on a premium model can blow through a standard user's
      |   whole month before any quota reacts.
      v
  No quota prevents a single expensive query. Only model RBAC does.


EVENT 4   weekly / month end
------------------------------------------------------------------------
  quota/06_topup.sql PART C     who still has a top-up? INCLUDE_USERS
                                has no TTL; sweep it or top-ups become
                                permanent.
  audit.sql                     TOPUP_STILL_ACTIVE, PREMIUM_MODEL_ACCESS,
                                spend outside the package
```

---

## What has been validated

Everything here was deployed end to end in a Snowflake demo account, exercised with a dedicated test user, and torn down again. Test limits were deliberately tiny (standard 1/3/5 credits, top-up 3/6/10) so real blocks cost a few credits.

| Check | Result |
| --- | --- |
| DCM deploy | 15 entities: 11 roles, 3 tags, 1 role alter |
| Quotas created observe-only | `BLOCK_ENFORCEMENT_ENABLED: false` on all four; operator in standard's `excluded_users` immediately |
| Top-up quota empty on creation | `GET_USERS` returned no rows: the unused-tag-value technique works |
| Blocking gate | `07_enable_blocking.sql` on 3-minute-old quotas raised `-20001` and exited 1 with nothing enabled. At 12 minutes it enabled all four |
| **Operator protection** | Operator (tagged `intensive` + named exclusion) was **never blocked** across 27 minutes of enforcement |
| **Real block** | Test user spent 1.26 against a 1.0 daily limit. Blocked **2.5 minutes** after the spend finished. Next call: `391936 ... Your access to AI_COMPLETE is blocked ... restored automatically ... on <UTC time>` |
| **Top-up unblocks** | Three statements from `06_topup.sql` PART B. The quota released the block **2 minutes 12 seconds** later in one run and **3 minutes 50 seconds** later in another; the next `AI_COMPLETE` succeeded (by 4m39s at the latest) |
| Accrued spend carries over | The same user was blocked again by the top-up at 3.43 of 3: the day's earlier spend counted |
| **Cycles are independent** | Raising only the top-up's MONTHLY limit left its DAILY block in place for the full 12m48s observed |
| **Top-up is per user** | A second user over the same limit stayed blocked while the first user was topped up and released (4m39s until the first user's next call worked) |
| **Return to standard carries spend** | After the documented reversal (`06_topup.sql` C3) the user kept working about 5 minutes, then standard blocked them again at 2.17 of 1.0 daily (5m08s after the sweep) |
| **Empty-array hazard** | `EXCLUDE_USERS('USER', [])` on a two-name list reported `cleared 2 user exclude(s)`, operator included; the documented clear-and-re-add kept the operator |
| **Without DCM** | The README tag snippet ran as written; the test users had AI access only through `PUBLIC` |
| **Cycle-start action** | Registered on the top-up quota, and a procedure that calls `INCLUDE_USERS([])` ran by hand. Never observed firing: it runs on the 1st of the month |
| **Admin summaries** | Received at the verified admin address: "users breached thresholds" (90% actual daily, 75% projected monthly) and "users were blocked". Blocks at 15:30 and 15:43 appeared in summaries at 15:36 and 15:46 |
| Teardown | `PURGE` dropped all 11 roles and 3 tags; every verify query returned empty |

Findings that change how you run it:

1. **Don't enable blocking in the same pass that creates the quota.** An earlier version of these scripts did. The standard quota blocked the operator on DAILY and MONTHLY even though `GET_QUOTA_SCOPE` already showed them excluded by tag *and* by name. `QUOTA_ACCESS_BLOCK_HISTORY` shows the block, then an `UNBLOCKED` 42 seconds later with no change made: the first evaluation used the all-users scope the quota was created with. The block emails had already gone out. Hence [quota/07_enable_blocking.sql](quota/07_enable_blocking.sql), whose re-run is the "operator protection" row above.
2. **Confirm scope changes with `GET_QUOTA_SCOPE`, not `GET_USERS`.** `GET_USERS` resolves through `TAG_REFERENCES` and lags. A help desk checking `GET_USERS` will think a top-up failed and grant a second one.
3. **For a block that just happened, ask the quota: `GET_ACTIVE_BLOCKS_V2` and `GET_ENFORCEMENT_HISTORY`.** `GET_ACTIVE_BLOCKS_V2` showed our block about a minute after it landed. `ACCOUNT_USAGE.QUOTA_ACCESS_BLOCK_HISTORY` lags (ours were there within 15 minutes). It also has no `START_TIME` or `END_TIME`: use `ACTION_AT`, `CYCLE`, `ACTION`, `CREDITS`, `PER_USER_LIMIT`, `BLOCKED_UNTIL`.
4. **DCM `account_identifier` must be `ORG-ACCOUNT_NAME`**, not the locator.
5. **Tear a DCM project down with `PURGE`, then `DROP`.** A drop alone leaves its roles and tags behind as unmanaged objects. This is documented behaviour.
6. **Blocked-user emails go only to verified addresses.** A brand-new user's email starts unverified, so for them expect the admin summary rather than the end-user email. Admin summaries come in two kinds, threshold breaches (actual or projected) and blocked users, and each block appeared in a summary about 2-5 minutes later. A dropped user's spend still counts for the rest of the cycle: a test user dropped four days earlier was blocked on WEEKLY by quotas created later that week, and appeared as `DROPPED_USER(<id>)`.
7. **Every quota change is logged in the account's event table, which is not always `SNOWFLAKE.TELEMETRY.EVENTS`.** Events under `snow.cost.quota` record creation, scope, limits, domains, thresholds, admin emails and every blocking switch, with a readable message. They didn't identify who made the change in the events we inspected, and they aren't evidence of email delivery. [audit.sql](audit.sql) QUERY 4 resolves the configured table and reads the log; QUERY 5 adds who ran each change from `QUERY_HISTORY`.
8. **A cycle-start action needs `USAGE` on the database and the schema for the `SNOWFLAKE` application, not just on the procedure.** Without those two grants, registering it failed with `INVALID_PROCEDURE_OR_MISSING_PERMISSIONS`; with them it registered.

---

## Without DCM

The quota scripts need exactly one object from Layer 1: the `AI_SPEND_TIER` tag, with `APPLYBUDGET` for whoever creates the quotas.

```sql
CREATE TAG IF NOT EXISTS <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER
    ALLOWED_VALUES 'standard', 'intensive', 'service', 'topup'
    COMMENT = 'Native quota selection; no model or feature permission';

GRANT APPLYBUDGET ON TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER
    TO ROLE <QUOTA_OWNER_ROLE>;
```

In teardown, replace the DCM `PURGE` step with `DROP TAG`.

---

## Placeholders

Every script uses the same placeholders. Bind them once.

| Placeholder | Meaning |
| --- | --- |
| `<CONTROL_DB>.<CONTROL_SCHEMA>` | Existing schema that holds the tag and the quotas |
| `<QUOTA_OWNER_ROLE>` | Role with `SNOWFLAKE.QUOTA_CREATOR`, `CREATE SNOWFLAKE.CORE.QUOTA` on the schema, and `APPLYBUDGET` on the tag |
| `<WAREHOUSE>` | Any warehouse, used only for session context |
| `<QUOTA_ADMIN_EMAILS>` | Comma-separated **verified** addresses; unverified ones are silently skipped |
| `<OPERATOR_USER>` | Whoever runs these quotas. Excluded from standard by name |
| `<USER_NAME>` | The user being tiered, topped up, or returned |
| `<ROLE_PREFIX>` | Role prefix from `dcm/manifest.yml` |
| `<EXPECTED_ACCOUNT_LOCATOR>` | Teardown guard: the non-production account you mean to clean |

There is no run-all launcher. Run each file deliberately and read its output before the next one.

---

## Boundaries

- **A quota isn't a per-request cost ceiling.** Enforcement is evaluated within minutes of spend, not before each request, so usage can overshoot the limit before the block lands (the docs' example: a 100-credit limit ending at 130). For AI functions, in-progress calls are terminated when the block takes effect. Model RBAC restricts which models users can call; a quota caps cumulative spend.
- **A quota exclusion isn't extra allowance.** It removes the ceiling entirely.
- **Named lists accumulate and have no TTL.** Passing an empty array clears the *whole* list, including your operator safety net.
- **Accrued spend doesn't reset** when a user moves tier.
- **Worst-case daily exposure is `users_in_tier × daily`**, not the per-user number.
- **Cortex Search isn't a quota domain.** Warehouse compute can't be mixed with AI domains and gets no block enforcement.
- **Unattributed spend** (no user) can't be governed by a per-user quota at all.

---

## Sources

- [Per-user quotas](https://docs.snowflake.com/en/user-guide/budgets/per-user-quotas)
- [QUOTA_ACCESS_BLOCK_HISTORY](https://docs.snowflake.com/en/user-guide/budgets/per-user-quotas) (no reference page yet; described in the per-user quotas guide)
- [DCM supported entities](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-supported-entities)
- [EXECUTE DCM PROJECT (PURGE)](https://docs.snowflake.com/en/sql-reference/sql/execute-dcm-project)
- [AI privileges and model access](https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql-privileges-and-access)
- [CoCo credit usage limits](https://docs.snowflake.com/en/user-guide/cortex-code/credit-usage-limit)

---

## Legal notice

Provided as is, without warranty of any kind. Not an official Snowflake product and not supported by Snowflake. Limits and timings are illustrative results from demo-account tests, not recommendations or service levels. Full text: [LEGAL_NOTICE.md](LEGAL_NOTICE.md).
