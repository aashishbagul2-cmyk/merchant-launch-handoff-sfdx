/**
 * Bulk-safe eligibility check for the merchant launch handoff.
 *
 * Every call re-reads current Opportunity + Primary Contract + Primary Quote state,
 * so it is safe to invoke from a record-triggered Flow on either Contract or
 * Opportunity, in any order, without trusting what field just changed.
 *
 * NOTE on scope: this is a working reference implementation for a take-home
 * assessment, not a production package. It assumes Salesforce CPQ is installed
 * (SBQQ__Quote__c, SBQQ__PrimaryQuote__c, SBQQ__Uncalculated__c are real managed
 * package fields) and that Contract.Status = 'Activated' is this org's stand-in
 * for "executed," since the standard Contract object has no literal "Executed"
 * value out of the box.
 */
public with sharing class LaunchEligibilityEvaluator {

    private static final Set<String> IN_FLIGHT_OR_DONE = new Set<String>{
        'Eligible', 'Event_Published', 'Downstream_Accepted', 'Launched'
    };

    @InvocableMethod(
        label='Evaluate Launch Eligibility'
        description='Bulk-safe eligibility check for the merchant launch handoff. Re-evaluates current state; does not trust the caller.'
    )
    public static void evaluate(List<Id> opportunityIds) {
        runEvaluation(opportunityIds, false);
    }

    // isRetry stops the requeue-once loop: if the retry attempt also hits a
    // lock, we don't requeue a second time. Two consecutive lock collisions
    // on the same Opportunity within about a minute is rare enough to accept
    // as a known limitation rather than build unbounded retry for; if it
    // happens, there's no handoff record yet for the sweeper to find either,
    // since the upsert never succeeded. Worth knowing about, not worth the
    // complexity of solving here.
    public static void runEvaluation(List<Id> opportunityIds, Boolean isRetry) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return;
        }

        // FOR UPDATE: locks these Opportunity rows for the transaction so a
        // concurrent Workato Contract sync and a rep saving the Opportunity
        // can't both write conflicting eligibility results. A losing transaction
        // gets a DmlException with UNABLE_TO_LOCK_ROW, caught below.
        List<Opportunity> opps = [
            SELECT Id,
                   Primary_Contract__c,
                   Primary_Contract__r.Status,
                   Primary_Contract__r.Pricing_Model__c,
                   Primary_Contract__r.Currency_Code__c,
                   Primary_Contract__r.ContractTerm,
                   Primary_Contract__r.Approved_Terms_Matched__c,
                   Primary_Contract__r.Contract_Version__c,
                   SBQQ__PrimaryQuote__c,
                   SBQQ__PrimaryQuote__r.Pricing_Model__c,
                   SBQQ__PrimaryQuote__r.Currency_Code__c,
                   SBQQ__PrimaryQuote__r.SBQQ__SubscriptionTerm__c,
                   SBQQ__PrimaryQuote__r.SBQQ__Uncalculated__c
            FROM Opportunity
            WHERE Id IN :opportunityIds
            FOR UPDATE
        ];
        if (opps.isEmpty()) {
            return;
        }

        // Quotes still mid-recalculation get skipped entirely, not logged as
        // a mismatch. SBQQ__Uncalculated__c just means the quote was saved
        // more recently than it was last calculated; treating that the same
        // as a real pricing mismatch would create a Blocked_Mismatch record
        // and a Case for something that's actually just a timing gap, and
        // whoever picks up that Case would be debugging a problem that isn't
        // there. When the recalculation finishes, the resulting Quote save
        // re-triggers evaluation on its own (see the Flow trigger note in
        // the design doc).
        List<Opportunity> readyOpps = new List<Opportunity>();
        for (Opportunity o : opps) {
            if (o.SBQQ__PrimaryQuote__c != null && o.SBQQ__PrimaryQuote__r.SBQQ__Uncalculated__c == true) {
                continue;
            }
            readyOpps.add(o);
        }
        if (readyOpps.isEmpty()) {
            return;
        }

        List<EvalOutcome> outcomes = new List<EvalOutcome>();
        Set<String> keys = new Set<String>();
        for (Opportunity o : readyOpps) {
            EvalOutcome outcome = evaluateOne(o);
            outcomes.add(outcome);
            keys.add(outcome.idempotencyKey);
        }

        Map<String, Merchant_Launch_Handoff__c> priorByKey = new Map<String, Merchant_Launch_Handoff__c>();
        for (Merchant_Launch_Handoff__c h : [
            SELECT Id, Idempotency_Key__c, Status__c
            FROM Merchant_Launch_Handoff__c
            WHERE Idempotency_Key__c IN :keys
        ]) {
            priorByKey.put(h.Idempotency_Key__c, h);
        }

        List<Merchant_Launch_Handoff__c> toUpsert = new List<Merchant_Launch_Handoff__c>();
        for (EvalOutcome outcome : outcomes) {
            toUpsert.add(new Merchant_Launch_Handoff__c(
                Idempotency_Key__c = outcome.idempotencyKey,
                Opportunity__c = outcome.opportunityId,
                Status__c = outcome.eligible ? 'Eligible' : 'Blocked_Mismatch',
                Eligibility_Snapshot__c = outcome.snapshotJson
            ));
        }

        try {
            // Upsert on the external ID: re-running this for the same
            // Opportunity/Contract pair always updates one record, never
            // creates a duplicate.
            upsert toUpsert Merchant_Launch_Handoff__c.Idempotency_Key__c;
        } catch (DmlException lockEx) {
            if (lockEx.getMessage().contains('UNABLE_TO_LOCK_ROW') && !isRetry) {
                // Lost the row lock to a concurrent transaction. Requeue this
                // batch once via Queueable rather than failing outright.
                // Delay is in minutes (0-10), not seconds, per
                // System.enqueueJob's real signature. Salesforce ignores the
                // delay during Apex tests and runs the job at
                // Test.stopTest(), which is what makes this retry path
                // testable, see RetryEligibilityEvaluatorTest.
                System.enqueueJob(new RetryEligibilityEvaluator(opportunityIds), 1);
                // Deliberately not rethrowing here. An enqueued Queueable
                // job is only durable if the transaction that enqueued it
                // actually commits, if this exception propagated up
                // uncaught, the whole transaction would roll back and take
                // the just-enqueued retry down with it, per Salesforce's own
                // documented behavior. Swallowing it here, so the
                // transaction commits, is what makes the retry real instead
                // of a job that silently never runs.
                return;
            }
            // Not a lock issue, or this was already the retry attempt: let
            // it surface. On the retry path this just fails the Queueable
            // job, visible in Setup > Apex Jobs, not a bigger rollback.
            throw lockEx;
        }

        List<Handoff_Event_Log__c> logs = new List<Handoff_Event_Log__c>();
        List<Merchant_Launch_Handoff__c> newlyEligible = new List<Merchant_Launch_Handoff__c>();

        for (Integer i = 0; i < outcomes.size(); i++) {
            EvalOutcome outcome = outcomes[i];
            Merchant_Launch_Handoff__c saved = toUpsert[i]; // Id is populated in place by the DML above
            Merchant_Launch_Handoff__c prior = priorByKey.get(outcome.idempotencyKey);

            logs.add(new Handoff_Event_Log__c(
                Handoff__c = saved.Id,
                Action__c = outcome.eligible ? 'Evaluated - Eligible' : 'Evaluated - Blocked: ' + outcome.reason,
                Automated__c = true,
                Snapshot__c = outcome.snapshotJson
            ));

            Boolean alreadyInFlight = prior != null && IN_FLIGHT_OR_DONE.contains(prior.Status__c);
            if (outcome.eligible && !alreadyInFlight) {
                newlyEligible.add(saved);
            }
        }

        if (!logs.isEmpty()) {
            insert logs;
        }

        publishEligibleTransitions(newlyEligible);
    }

    private static void publishEligibleTransitions(List<Merchant_Launch_Handoff__c> newlyEligible) {
        if (newlyEligible.isEmpty()) {
            return;
        }

        List<Merchant_Launch_Eligible__e> events = new List<Merchant_Launch_Eligible__e>();
        for (Merchant_Launch_Handoff__c h : newlyEligible) {
            events.add(new Merchant_Launch_Eligible__e(
                Handoff_Id__c = h.Id,
                Opportunity_Id__c = h.Opportunity__c
            ));
        }

        // The event definition's Publish Behavior is set to Publish After
        // Commit (see the object metadata), so Workato can never see this
        // signal for a handoff record that didn't actually get saved.
        List<Database.SaveResult> results = EventBus.publish(events);

        for (Integer i = 0; i < results.size(); i++) {
            newlyEligible[i].Status__c = results[i].isSuccess() ? 'Event_Published' : 'Eligible';
        }
        update newlyEligible;
    }

    private static EvalOutcome evaluateOne(Opportunity o) {
        // Null-safety note: Primary_Contract__r.* and SBQQ__PrimaryQuote__r.*
        // are only ever dereferenced inside an else-if branch that already
        // ruled out a null Primary_Contract__c / SBQQ__PrimaryQuote__c in the
        // branch above it, so an unlinked Contract or Quote can't reach the
        // line that touches it. The one real gap this doesn't cover: this
        // class runs `with sharing`, so if the running context lacks read
        // access to the specific Contract or Quote record, the relationship
        // could come back null even with a populated lookup Id. Assumes the
        // automated context this runs under has read access to both.
        EvalOutcome outcome = new EvalOutcome();
        outcome.opportunityId = o.Id;

        String contractPart = (o.Primary_Contract__c != null)
            ? String.valueOf(o.Primary_Contract__c) + ':v' + String.valueOf(o.Primary_Contract__r.Contract_Version__c)
            : 'no-contract';
        outcome.idempotencyKey = o.Id + ':' + contractPart;

        if (o.Primary_Contract__c == null) {
            outcome.reason = 'Executed contract is missing';
        } else if (o.Primary_Contract__r.Status != 'Activated') {
            outcome.reason = 'Contract is not executed';
        } else if (o.SBQQ__PrimaryQuote__c == null) {
            outcome.reason = 'Primary quote is missing';
        } else if (o.SBQQ__PrimaryQuote__r.Pricing_Model__c != o.Primary_Contract__r.Pricing_Model__c) {
            outcome.reason = 'Pricing model does not match';
        } else if (o.SBQQ__PrimaryQuote__r.Currency_Code__c != o.Primary_Contract__r.Currency_Code__c) {
            outcome.reason = 'Currency does not match';
        } else if (o.SBQQ__PrimaryQuote__r.SBQQ__SubscriptionTerm__c != o.Primary_Contract__r.ContractTerm) {
            outcome.reason = 'Term does not match';
        } else if (o.Primary_Contract__r.Approved_Terms_Matched__c != true) {
            outcome.reason = 'Approved terms do not match';
        } else {
            outcome.eligible = true;
            outcome.reason = 'Eligible';
        }

        Map<String, Object> snapshot = new Map<String, Object>{
            'opportunityId' => String.valueOf(o.Id),
            'result' => outcome.reason,
            'evaluatedAt' => Datetime.now().getTime()
        };
        outcome.snapshotJson = JSON.serialize(snapshot);
        return outcome;
    }

    private class EvalOutcome {
        Id opportunityId;
        String idempotencyKey;
        Boolean eligible = false;
        String reason;
        String snapshotJson;
    }
}
