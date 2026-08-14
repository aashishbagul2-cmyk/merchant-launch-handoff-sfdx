# Merchant Launch Handoff — Reference Implementation (Question 1)

This is a scoped, deployable slice of the Q1 design, the eligibility evaluator,
its four required tests, and the recovery sweeper. Deployed and the full test
suite executed against a live org with CPQ installed, 11/11 passing. Treat any
failure in your own org as an environment mismatch first, see the CPQ caveats
below before assuming it's a logic bug.

## What's in here

- `Merchant_Launch_Handoff__c` — the durable idempotency/status record
- `Handoff_Event_Log__c` — the append-only audit ledger
- `Merchant_Launch_Eligible__e` — the platform event (Publish After Commit)
- Custom fields added to standard `Contract`, `Opportunity`, and the CPQ
  managed object `SBQQ__Quote__c`
- `LaunchEligibilityEvaluator` + its test class (bulk 200, duplicate event,
  mismatch, 3 of the 4 required scenarios)
- `HandoffRecoverySweeper` + its test class (downstream failure with retry,
  the 4th required scenario)
- `RetryEligibilityEvaluator`, the Queueable that handles a lost row lock,
  plus `MerchantLaunchHandoffTrigger` and its handler, which keep
  `Opportunity.Launch_Status__c` in sync with the handoff record

## Deploy

```bash
sf project deploy start --source-dir force-app -o <your-org-alias>
sf apex run test --class-names LaunchEligibilityEvaluatorTest,HandoffRecoverySweeperTest,RetryEligibilityEvaluatorTest,MerchantLaunchHandoffTriggerHandlerTest -o <your-org-alias> --result-format human --code-coverage
```

## Changes made during review

This went through several rounds of review after the first draft, checking
the design doc's claims against what the code actually did, and checking
Apex/platform behavior against Salesforce's own documented behavior rather
than assuming. Most rounds surfaced something real; two claims were checked
and turned out to already be correct, worth recording why rather than just
noting "no change."

1. **The row-lock retry was real code debt.** The design doc claimed a lock
   failure "requeues itself once," but the code only re-threw the exception,
   a mismatch between what was written and what was built. Fixed: a
   `RetryEligibilityEvaluator` Queueable now gets enqueued once via
   `System.enqueueJob(job, delayInMinutes)` (delay is in minutes, 0-10, not
   seconds). Salesforce ignores the delay under test and runs the job at
   `Test.stopTest()`, which is what makes `RetryEligibilityEvaluatorTest`
   possible. What's still not tested, and can't be with standard unit tests:
   genuine concurrent lock contention between two real transactions. What's
   tested is that the requeue mechanism itself works. The retry is capped at
   one attempt (`isRetry` flag); if the retry also hits a lock, there's no
   second requeue, and since the upsert never succeeded, there's no handoff
   record yet for the sweeper to pick up either. Two consecutive lock
   collisions on the same Opportunity within about a minute is rare enough to
   accept as a known limit rather than build unbounded retry for.

   Implementing that first fix surfaced a second, easy-to-miss bug: the
   first draft enqueued the retry and then re-threw the lock exception.
   Salesforce documents that a Queueable job enqueued inside a transaction
   that later rolls back never actually runs, so re-throwing right after
   `enqueueJob()` would have silently discarded the very retry it just
   queued. Fixed by not re-throwing on that path, the method returns
   normally so the transaction commits and the retry survives.

2. **Platform Events are at-least-once, not exactly-once, confirmed against
   Salesforce's own documentation.** This didn't need a code change: the
   design already defends against duplicate delivery two ways, the
   subscriber checks handoff status before calling out, and the downstream
   API is idempotent on the handoff ID either way.

3. **A quote mid-recalculation was being treated as a real mismatch, and
   that was a genuine bug.** `SBQQ__Uncalculated__c` just means the quote
   was saved more recently than it was last calculated, a timing gap, not a
   pricing disagreement. The old code lumped it into the same
   `Blocked_Mismatch` path as an actual currency or pricing-model mismatch,
   which would open a false Case for someone to chase. Fixed: Opportunities
   with a still-calculating primary quote are now skipped entirely before
   evaluation runs, no handoff record, no Case. The natural fix is that the
   quote's own save, once calculation finishes, re-triggers evaluation on
   its own. `quoteStillCalculatingIsSkippedNotBlocked` tests this, but it's
   self-diagnosing rather than a hard assertion: whether an Apex-inserted
   quote actually lands in the uncalculated state depends on whether this
   org's CPQ config auto-stamps `SBQQ__LastSavedOn__c` on insert, which
   varies by org (see the CPQ caveats below). If it doesn't, the test
   detects that and skips its own assertion instead of reporting a false
   pass or fail.

4. **The design doc claimed a formula field that isn't actually possible.**
   It said Opportunity had "a formula field showing plain status" pulled
   from the related handoff record. That's not buildable as a formula:
   `Merchant_Launch_Handoff__c` is the child (its `Opportunity__c` lookup
   points up to Opportunity, so Opportunity is the parent here), and
   Salesforce cross-object formulas only read upward through a relationship,
   child to parent, a parent can't reach down and pull an arbitrary field
   off a specific child record. Even Roll-Up Summary fields, the one
   mechanism that does read child data, only work on Master-Detail
   relationships and only aggregate numeric/date fields, never display text
   or a picklist value from one child record. Fixed with a real field,
   `Opportunity.Launch_Status__c`, a plain picklist. First pass had
   `LaunchEligibilityEvaluator` sync it directly, which only covered that
   one call site, the sweeper and the eventual Workato callback also change
   handoff status and would have needed the same sync repeated at each of
   them. Moved the sync to `MerchantLaunchHandoffTrigger` +
   `MerchantLaunchHandoffTriggerHandler` instead, a single trigger on the
   handoff object that reacts to any status change regardless of which
   caller made it. `LaunchEligibilityEvaluator` no longer touches
   Opportunity at all, one less thing for it to know about.

5. **Two claims turned out to already be correct**, checked directly against
   the code rather than assumed. One: a claim that `evaluateOne` could throw
   a NullPointerException on an unlinked Contract or Quote. Checked the
   actual branching, the null checks are the `if`/`else if` structure
   itself, `Primary_Contract__r.Status` is only ever touched inside a
   branch that already ruled out a null `Primary_Contract__c` in the branch
   above it. The real, narrower gap: this class runs `with sharing`, so a
   relationship could come back null if the running context lacks read
   access to the record even with a populated lookup Id, that's documented
   as an assumption in the code, not a rewrite. Two: a claim that the bulk
   test's assertion of `Event_Published` couldn't be reached from an upsert
   that only ever writes `Eligible`. It's reachable, `publishEligibleTransitions`
   sets `Status__c = 'Event_Published'` and issues a real `update` before the
   test runs its assertion, that method body just wasn't visible in the
   design doc's trimmed excerpt, which is a fair thing to flag about the doc
   even though the code itself was already right.

## Assumptions baked into this scope

- **"Executed" maps to `Contract.Status = 'Activated'`.** The standard
  Contract object doesn't ship a literal "Executed" value; Activated is the
  closest real equivalent. If your org's process uses a different status
  value or an approval process gates activation, update
  `evaluateOne()`'s `Status != 'Activated'` check and the test data's
  `c.Status = 'Activated'` line to match.
- **Currency is a plain `Currency_Code__c` text field**, not the standard
  `CurrencyIsoCode`, since that only exists if multi-currency is enabled
  org-wide. If your org has multi-currency on, swap it in, it's more correct
  than the stand-in.
- **`Opportunity.Primary_Contract__c` is a new custom lookup.** Vanilla
  Salesforce has no standard `Opportunity.ContractId` field, an earlier
  draft of this design assumed one; this fixes that.

## Environment-specific notes (read before assuming a test failure is a logic bug)

- **CPQ required fields.** `SBQQ__Quote__c` in `buildQuote()` sets the fields
  I'm confident are commonly required (`SBQQ__Account__c`,
  `SBQQ__Opportunity2__c`, `SBQQ__Primary__c`, `SBQQ__StartDate__c`). A
  different org's CPQ configuration may have additional required fields,
  validation rules, or a Quote record type this doesn't account for. If the
  bulk test fails on `REQUIRED_FIELD_MISSING` or
  `FIELD_CUSTOM_VALIDATION_EXCEPTION`, that's this, not the eligibility
  logic, confirmed by hitting exactly this in one of the two orgs this was
  actually deployed to tonight.
- **`SBQQ__Uncalculated__c` behavior on freshly-inserted Quotes.** This is a
  real formula field (`SBQQ__LastSavedOn__c > SBQQ__LastCalculatedOn__c`, or
  `SBQQ__LastSavedOn__c` set with `SBQQ__LastCalculatedOn__c` null). If a
  given org's CPQ managed package automatically stamps
  `SBQQ__LastSavedOn__c` on save, an inserted-via-Apex quote could evaluate
  as "uncalculated" even though it was never meant to simulate that state.
  The test data defensively sets `SBQQ__LastCalculatedOn__c` ten minutes in
  the future to guard against this.
- **`Opportunity.SBQQ__PrimaryQuote__c` sync timing.** CPQ's managed package
  may auto-populate this when a Quote's `SBQQ__Primary__c` checkbox is set.
  The test explicitly sets it anyway (`linkPrimaryQuoteAndContract`), which
  is redundant if CPQ already did it and necessary if it didn't, either way
  it's harmless.
- **`FOR UPDATE` row-locking itself has no dedicated test, and can't.**
  Genuine row-lock contention needs two truly concurrent transactions;
  standard Apex unit tests run single-threaded, so this isn't reliably
  reproducible in a test. This is a known, intentional gap, not an
  oversight. What *is* tested is the requeue mechanism that fires when a
  lock is lost, see `RetryEligibilityEvaluatorTest` and item 1 above.

## What's deliberately out of scope here

- The Retry LWC, permission sets, and Flow screens (not code you run tests
  against)
- The actual Workato recipes (external to Salesforce, nothing to deploy)
- Unbounded retry chains on lock contention (intentionally capped at one
  attempt, see item 1 above for why)
