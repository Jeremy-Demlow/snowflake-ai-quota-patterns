# Quota Runbook

Operator procedures for the per-user AI quotas. Everything here is a live call against the quota objects — no snapshot tables, no scheduled jobs, no warehouse.

Design rationale, the three ASCII charts, and the sizing rule are in [../README.md](../README.md). This file is the "what do I type" companion.

---

## Live state: the four questions

These replace the snapshot-table approach that earlier versions of this package used. The native methods and the `ACCOUNT_USAGE` view answer every question directly, so there is nothing to capture and nothing to go stale.

### Who is blocked right now, and by which quota?

Start account-wide. A user can be in more than one quota, and each blocks independently.

```sql
SELECT ACTION_AT,
       QUOTA_NAME,
       USER_NAME,
       CYCLE,                 -- DAILY / WEEKLY / MONTHLY. Fix THIS cycle.
       ACTION,
       CREDITS,               -- what they had spent
       PER_USER_LIMIT,        -- against what ceiling
       BLOCKED_UNTIL          -- if this is soon, doing nothing is the answer
FROM SNOWFLAKE.ACCOUNT_USAGE.QUOTA_ACCESS_BLOCK_HISTORY
WHERE ACTION_AT >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY ACTION_AT DESC
LIMIT 50;
```

`ACCOUNT_USAGE` lags. In validation a block was in this view within 15 minutes, while the quota's own `GET_ACTIVE_BLOCKS_V2` showed it about a minute after it landed. For a block that just happened, ask the quota directly; `GET_ENFORCEMENT_HISTORY` gives exact block and unblock times:

```sql
CALL QUOTA_AI_STANDARD!GET_ENFORCEMENT_HISTORY('<START_DATE_UTC>', '<END_DATE_UTC>');
```

Then confirm per quota:

```sql
CALL QUOTA_AI_STANDARD!GET_ACTIVE_BLOCKS_V2();
CALL QUOTA_AI_INTENSIVE!GET_ACTIVE_BLOCKS_V2();
CALL QUOTA_AI_SERVICE!GET_ACTIVE_BLOCKS_V2();
CALL QUOTA_AI_TOPUP!GET_ACTIVE_BLOCKS_V2();
```

### Who is in this quota?

```sql
CALL QUOTA_AI_STANDARD!GET_QUOTA_SCOPE();   -- tags, operator, named in/out lists
CALL QUOTA_AI_STANDARD!GET_USERS();         -- resolved membership
```

`GET_QUOTA_SCOPE` is immediate. `GET_USERS` resolves through `TAG_REFERENCES`, which lags up to roughly two hours — a tag set minutes ago may not appear. A gap means **not yet observed**, never "not covered".

**Confirm a scope change with `GET_QUOTA_SCOPE`, not `GET_USERS`.** Validated by running it: immediately after `INCLUDE_USERS(['<USER_NAME>'])`, `GET_QUOTA_SCOPE` listed the user in `included_users` while `GET_USERS` still returned no rows. An operator who checks `GET_USERS` will wrongly conclude the change failed.

### What are this quota's settings?

```sql
CALL QUOTA_AI_STANDARD!GET_CONFIG();                  -- limits + BLOCK_ENFORCEMENT_ENABLED
CALL QUOTA_AI_STANDARD!GET_NOTIFICATION_THRESHOLDS();
```

### What did a user actually spend?

```sql
CALL QUOTA_AI_STANDARD!GET_SPENDING_DETAILS_BY_USERS('2026-09-01', '2026-09-30');
```

Takes a **date range, not a user list**. The range must fall in the current or prior calendar month; earlier dates return nothing.

### What changed, and who changed it?

Every configuration change to a quota writes an event to the account's event table: limits, scope lists, tags, domains, thresholds, admin emails, and every switch of blocking on or off. It is a native change log with nothing to deploy. [../audit.sql](../audit.sql) QUERY 4 reads it; QUERY 5 adds who ran each change from `QUERY_HISTORY`.

```sql
SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT;   -- use THIS table, not an assumed default

SELECT TIMESTAMP,
       RESOURCE_ATTRIBUTES:"snow.cost.quota.name"::STRING AS quota_name,
       RECORD:name::STRING   AS event_name,      -- e.g. QUOTA_BLOCK_ENFORCEMENT_ENABLED_UPDATED
       VALUE:message::STRING AS change           -- e.g. "User exclude list updated. USER_COUNT=1"
FROM <EVENT_TABLE_FROM_ABOVE>
WHERE SCOPE['name']::STRING = 'snow.cost.quota'
ORDER BY TIMESTAMP DESC;
```

Two things it does **not** tell you. It has no user or role, so pair it with `QUERY_HISTORY`. And it is not evidence that a notification email was delivered: in validation it held no delivery events at all, including for block emails that did arrive.

---

## Deploy the quotas

Full deployment context, including the DCM steps that must come first, is in [../README.md](../README.md) under "How they deploy it".

| Order | File | Why this position |
| --- | --- | --- |
| 1 | [00_size_limits.sql](00_size_limits.sql) | Customer runs it in their own account. Sets every number below. |
| 2 | [01_assign_tiers.sql](01_assign_tiers.sql) | Tags must exist before quotas, or heavy users sit in the low limit for the ~2h propagation window. |
| 3 | [02_tier_service.sql](02_tier_service.sql) | Carve out pipelines. |
| 4 | [03_tier_intensive.sql](03_tier_intensive.sql) | Carve out power users. |
| 5 | [04_tier_standard.sql](04_tier_standard.sql) | All users minus those tags. **Last**, because a new quota defaults to all users. |
| 6 | [06_topup.sql](06_topup.sql) PART A | Empty by default. Ready for the first escalation. |
| 7 | [07_enable_blocking.sql](07_enable_blocking.sql) | **At least 10 minutes later.** The only file that enables blocking. Refuses to run on a quota under 10 minutes old; enables standard last. |

Inside every tier file the pattern is identical and the order is deliberate:

```
create  ->  scope  ->  domains  ->  DAILY limit  ->  weekly  ->  monthly
        ->  notifications  ->  read scope back        (observe-only)

  ... wait >= 10 minutes ...

07_enable_blocking.sql  ->  gate  ->  read all scopes  ->  enable, standard last
```

Daily first so the blast-radius control exists before the budget control. **Blocking is never enabled in the pass that creates a quota.** In validation, a standard quota whose blocking was enabled seconds after creation blocked the operator on DAILY and MONTHLY, even though `GET_QUOTA_SCOPE` already showed them excluded. A new quota starts as ALL USERS, and exclusions take ~5-10 minutes to reach enforcement (tag-based ones up to ~2 hours), so anyone who must never be blocked should also be excluded **by name**.

---

## Someone is blocked

```
1. Diagnose        which quota, which cycle, how far over, until when
                   -> the query at the top of this file
                   -> 05_escalate.sql STEP 0

2. Pick ONE option

   Option 1  top-up            06_topup.sql PART B      most escalations
   Option 2  move their tier   05_escalate.sql          new normal
   Option 3  raise the tier    05_escalate.sql          sizing was wrong
   Option 4  wait              05_escalate.sql          limit was correct
```

Raising **MONTHLY** does **not** clear a **DAILY** or **WEEKLY** block. Each cycle is evaluated and released independently. This is the most common wasted on-call cycle.

### What a top-up is, and is not

The top-up quota is a second, higher **ceiling** on the same running total, not an extra allowance on top of it. Spend is counted once per cycle and each quota judges it against its own limit.

| Standard | Top-up | Headroom after moving |
| --- | --- | --- |
| 50 daily | 100 daily | 50 more today |
| 250 monthly | 350 monthly | 100 more this month |

- A user at 250 of 250 monthly who moves to top-up is at 250 of 350: 100 left. A user at 240 has 110 left. Nothing resets on the move.
- Everyone in the top-up quota shares the same limits. One quota cannot give Alice +100 and Bob +300; that needs a second top-up quota.
- Only the people you add by name are in it. Topping up one user leaves everyone else in standard untouched.

### The usual answer: a top-up

Three statements. Measured in validation: the quota's own record showed the block released 2 minutes 12 seconds after they ran in one run and 3 minutes 50 seconds in another, and the user's next call worked by 4 minutes 39 seconds at the latest; tell the user up to 10. Full procedure and the reversal footgun are in [06_topup.sql](06_topup.sql).

```sql
CALL QUOTA_AI_TOPUP!INCLUDE_USERS(['<USER_NAME>']);
CALL QUOTA_AI_STANDARD!EXCLUDE_USERS('USER', ['<USER_NAME>']);
ALTER USER "<USER_NAME>" SET TAG <CONTROL_DB>.<CONTROL_SCHEMA>.AI_SPEND_TIER = 'topup';
```

All three are required. The second one is the one people forget: quotas evaluate independently, so standard keeps blocking until the user is out of it.

---

## Weekly: sweep the top-ups

`INCLUDE_USERS` and `EXCLUDE_USERS` accumulate and have **no TTL**. Nothing in Snowflake expires a top-up. This review is the only thing that does.

```sql
CALL QUOTA_AI_TOPUP!GET_QUOTA_SCOPE();
```

For each name: still needed, move to a real tier, or return to standard. Second top-up in a month means the tier is wrong, not that they need another top-up. Reversal procedure is [06_topup.sql](06_topup.sql) PART C.

**Spend does not reset when you return a user to standard.** In validation the user kept working for about 5 minutes after the reversal, then standard blocked them again at 2.17 against a 1.0 daily limit. Check spend first (PART C2) and sweep soon after the monthly reset, when counters are near zero. A sweep mid-month blocks anyone still above standard's limits.

**A top-up does not end on its own**, including at the month boundary. The user keeps the top-up limits until someone sweeps. A cycle-start action can run a procedure on the 1st of each UTC month, but the registration below is all that was verified. See the end of [06_topup.sql](06_topup.sql).

**Never clear a named list with an empty array to remove one person.** `EXCLUDE_USERS('USER', [])` clears the *entire* list — in the lab that removes the operator safety net on `QUOTA_AI_STANDARD`. Capture the list, then rebuild it.

---

## Monthly: review the sizing

```sql
-- Actual per-user spend against the ceilings
CALL QUOTA_AI_STANDARD!GET_SPENDING_DETAILS_BY_USERS('<START>', '<END>');
CALL QUOTA_AI_INTENSIVE!GET_SPENDING_DETAILS_BY_USERS('<START>', '<END>');
```

Then check the sizing rule still holds for every tier:

```
daily  <  weekly  <  monthly  <  daily x days_in_month
```

Raising daily above weekly makes the daily limit unreachable, because weekly always trips first, and silently removes your blast-radius control. Worst-case account exposure for one day is `users_in_tier x daily`, not the per-user number — recompute it whenever a limit changes.

Record any change in your `quotas.yml` (copied from [../quotas.example.yml](../quotas.example.yml)), or the next release reverts it.

---

## Tear it down

Non-production: [99_teardown.sql](99_teardown.sql). Guarded to the account locator you bind.

Order matters — enforcement is disabled before the quotas are dropped, so blocked users are released observably rather than left to a quota that no longer exists. The DCM project is removed with `EXECUTE DCM PROJECT ... PURGE` and then `DROP DCM PROJECT`; a drop on its own leaves the roles and tags behind as unmanaged objects.

It does not delete metering history, does not restore PUBLIC's AI access if you revoked it, and does not drop the containing database.

---

## Things that will bite you

| Symptom | Cause |
| --- | --- |
| Raised the limit, still blocked | Wrong cycle. Validated: raising only MONTHLY left a DAILY block in place for the full 12m48s observed. Or a second quota is also blocking them. |
| User says "blocked" but no block shows | `QUOTA_ACCESS_BLOCK_HISTORY` can lag (ours: within 15 min). Use `GET_ENFORCEMENT_HISTORY` on the quota. A real block is error `391936` and names the UTC release time. |
| Tagged the user, nothing changed | `TAG_REFERENCES` lags ~2h. Use `INCLUDE_USERS` for immediate effect. |
| Moved them to a higher tier, still blocked | Accrued spend does not reset on a tier move. |
| New quota blocked everyone | A new quota defaults to **all users**. Scope it before enabling blocking. |
| Operator blocked right after deploy | Blocking was enabled before the exclusion propagated. Disable standard, wait 10 minutes, re-run [07_enable_blocking.sql](07_enable_blocking.sql). |
| Top-up user still blocked | Missing the `EXCLUDE_USERS` on standard. Both quotas evaluate. |
| Cleared one exception, lost several | Empty array clears the whole list. |
| Cortex Search spend ungoverned | Not a quota domain. Cannot be controlled this way. |
| One query burned the month | Enforcement is minutes-latent. That is a model RBAC problem. |
| Quota shows 0 users | `GET_USERS` lag, or the scope really is empty. Check `GET_QUOTA_SCOPE`. |
| Top-up looks like it did not apply | You checked `GET_USERS`. Check `GET_QUOTA_SCOPE`: named inclusion registers there immediately. |
| Docs' event-table query returns nothing | The account's `EVENT_TABLE` parameter points at a custom table. Check `SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT`. |
| Admin summary lists `DROPPED_USER(<id>)` | A user dropped earlier in the cycle still has spend in it, and a quota can block them even after the drop (including a quota created later in the cycle). Harmless; it clears at the cycle reset. |
| DCM warns about an account mismatch | `account_identifier` in the manifest must be the org-qualified `ORG-ACCOUNT_NAME`, not the account locator. |
| Roles and tags still exist after teardown | `DROP DCM PROJECT` was run without `PURGE` first. Use the fallback block in [99_teardown.sql](99_teardown.sql). |
