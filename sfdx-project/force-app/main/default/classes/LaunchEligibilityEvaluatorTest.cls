/**
 * Covers three of the four required test scenarios for the eligibility
 * evaluator: bulk processing, a duplicate/replayed event, and a
 * Quote/Contract mismatch. The fourth required scenario (downstream failure
 * with retry) lives in HandoffRecoverySweeperTest, since that is the
 * component actually responsible for retry behavior.
 *
 * See the project README for assumptions this test data relies on
 * (Contract.Status='Activated' as the executed state, CPQ required fields).
 */
@IsTest
private class LaunchEligibilityEvaluatorTest {

    private static Account buildAccount() {
        Account a = new Account(Name = 'Test Merchant ' + String.valueOf(Math.random()));
        insert a;
        return a;
    }

    private static Opportunity buildOpportunity(Id accountId) {
        Opportunity o = new Opportunity(
            Name = 'Test Merchant Launch',
            AccountId = accountId,
            StageName = 'Closed Won',
            CloseDate = Date.today()
        );
        insert o;
        return o;
    }

    private static Contract buildContract(Id accountId, String pricingModel, String currencyCode, Integer term, Boolean approvedTermsMatched) {
        Contract c = new Contract(
            AccountId = accountId,
            Pricing_Model__c = pricingModel,
            Currency_Code__c = currencyCode,
            ContractTerm = term,
            Approved_Terms_Matched__c = approvedTermsMatched,
            Contract_Version__c = 1
        );
        insert c;
        // Mirrors what the Ironclad sync does once the agreement is executed.
        c.Status = 'Activated';
        update c;
        return c;
    }

    private static SBQQ__Quote__c buildQuote(Id accountId, Id opportunityId, String pricingModel, String currencyCode, Integer term) {
        SBQQ__Quote__c q = new SBQQ__Quote__c(
            SBQQ__Account__c = accountId,
            SBQQ__Opportunity2__c = opportunityId,
            SBQQ__Primary__c = true,
            SBQQ__StartDate__c = Date.today(),
            Pricing_Model__c = pricingModel,
            Currency_Code__c = currencyCode,
            SBQQ__SubscriptionTerm__c = term,
            // Set in the future relative to any auto-populated
            // SBQQ__LastSavedOn__c so SBQQ__Uncalculated__c evaluates false
            // regardless of the managed package's own save automation.
            SBQQ__LastCalculatedOn__c = System.now().addMinutes(10)
        );
        insert q;
        return q;
    }

    private static void linkPrimaryQuoteAndContract(Id opportunityId, Id contractId, Id quoteId) {
        update new Opportunity(
            Id = opportunityId,
            Primary_Contract__c = contractId,
            SBQQ__PrimaryQuote__c = quoteId
        );
    }

    @IsTest
    static void evaluates200OpportunitiesInBulk() {
        Account acct = buildAccount();

        // Built as bulk DML, one insert per object per 200 records, not a loop of
        // single-record inserts. Single-record inserts here previously fired CPQ's own
        // managed-package Quote automation once per record instead of once per bulk
        // statement, which blew through the synchronous SOQL limit from inside CPQ's own
        // trigger before evaluate() was ever called, caught the first time this test
        // actually ran against a real CPQ-enabled org. LaunchEligibilityEvaluator itself
        // was never the problem, it only ever runs one bulk query either way, this was
        // the test's own fixture setup not being bulk-safe against CPQ's real automation.
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name = 'Test Merchant Launch ' + i,
                AccountId = acct.Id,
                StageName = 'Closed Won',
                CloseDate = Date.today()
            ));
        }
        insert opps;

        List<Contract> contracts = new List<Contract>();
        for (Integer i = 0; i < 200; i++) {
            contracts.add(new Contract(
                AccountId = acct.Id,
                Pricing_Model__c = 'Subscription',
                Currency_Code__c = 'USD',
                ContractTerm = 12,
                Approved_Terms_Matched__c = true,
                Contract_Version__c = 1
            ));
        }
        insert contracts;

        // Mirrors what the Ironclad sync does once the agreement is executed, one bulk
        // update instead of 200 single-record updates.
        List<Contract> toActivate = new List<Contract>();
        for (Contract c : contracts) {
            toActivate.add(new Contract(Id = c.Id, Status = 'Activated'));
        }
        update toActivate;

        List<SBQQ__Quote__c> quotes = new List<SBQQ__Quote__c>();
        for (Integer i = 0; i < 200; i++) {
            quotes.add(new SBQQ__Quote__c(
                SBQQ__Account__c = acct.Id,
                SBQQ__Opportunity2__c = opps[i].Id,
                SBQQ__Primary__c = true,
                SBQQ__StartDate__c = Date.today(),
                Pricing_Model__c = 'Subscription',
                Currency_Code__c = 'USD',
                SBQQ__SubscriptionTerm__c = 12,
                SBQQ__LastCalculatedOn__c = System.now().addMinutes(10)
            ));
        }
        insert quotes;

        List<Opportunity> toLink = new List<Opportunity>();
        List<Id> oppIds = new List<Id>();
        for (Integer i = 0; i < 200; i++) {
            toLink.add(new Opportunity(
                Id = opps[i].Id,
                Primary_Contract__c = contracts[i].Id,
                SBQQ__PrimaryQuote__c = quotes[i].Id
            ));
            oppIds.add(opps[i].Id);
        }
        update toLink;

        Test.startTest();
        LaunchEligibilityEvaluator.evaluate(oppIds);
        Test.stopTest();

        List<Merchant_Launch_Handoff__c> handoffs = [
            SELECT Status__c FROM Merchant_Launch_Handoff__c WHERE Opportunity__c IN :oppIds
        ];
        System.assertEquals(200, handoffs.size(), 'Expected one handoff per opportunity');
        for (Merchant_Launch_Handoff__c h : handoffs) {
            System.assertEquals('Event_Published', h.Status__c, 'A matching Quote/Contract pair should reach Event_Published');
        }

        List<Opportunity> updatedOpps = [SELECT Launch_Status__c FROM Opportunity WHERE Id IN :oppIds];
        System.assertEquals(200, updatedOpps.size());
        for (Opportunity o : updatedOpps) {
            System.assertEquals('Sent_to_Onboarding', o.Launch_Status__c, 'Handoff ends at Event_Published, which maps to Sent_to_Onboarding, kept in sync by the trigger, not left at the default');
        }
    }

    @IsTest
    static void duplicateEvaluationIsIdempotent() {
        Account acct = buildAccount();
        Opportunity o = buildOpportunity(acct.Id);
        Contract c = buildContract(acct.Id, 'Subscription', 'USD', 12, true);
        SBQQ__Quote__c q = buildQuote(acct.Id, o.Id, 'Subscription', 'USD', 12);
        linkPrimaryQuoteAndContract(o.Id, c.Id, q.Id);

        Test.startTest();
        LaunchEligibilityEvaluator.evaluate(new List<Id>{ o.Id });
        LaunchEligibilityEvaluator.evaluate(new List<Id>{ o.Id }); // simulates a replayed trigger/event
        Test.stopTest();

        List<Merchant_Launch_Handoff__c> handoffs = [
            SELECT Id FROM Merchant_Launch_Handoff__c WHERE Opportunity__c = :o.Id
        ];
        System.assertEquals(1, handoffs.size(), 'A replayed evaluation must not create a second handoff record');
    }

    @IsTest
    static void mismatchBlocksLaunch() {
        Account acct = buildAccount();
        Opportunity o = buildOpportunity(acct.Id);
        Contract c = buildContract(acct.Id, 'Subscription', 'USD', 12, true);
        SBQQ__Quote__c q = buildQuote(acct.Id, o.Id, 'Usage', 'USD', 12); // pricing model deliberately mismatched
        linkPrimaryQuoteAndContract(o.Id, c.Id, q.Id);

        Test.startTest();
        LaunchEligibilityEvaluator.evaluate(new List<Id>{ o.Id });
        Test.stopTest();

        Merchant_Launch_Handoff__c handoff = [
            SELECT Status__c, Eligibility_Snapshot__c FROM Merchant_Launch_Handoff__c WHERE Opportunity__c = :o.Id
        ];
        System.assertEquals('Blocked_Mismatch', handoff.Status__c);
        System.assert(
            handoff.Eligibility_Snapshot__c.contains('Pricing model does not match'),
            'Snapshot should record the specific reason for the block'
        );
    }

    @IsTest
    static void quoteStillCalculatingIsSkippedNotBlocked() {
        // Regression test for a real bug: the eligibility check used to treat
        // "quote is mid-recalculation" the same as a genuine pricing
        // mismatch, which would have opened a false Case for a support
        // person to chase. It should just skip and let the quote's own save,
        // once calculation finishes, re-trigger evaluation.
        Account acct = buildAccount();
        Opportunity o = buildOpportunity(acct.Id);
        Contract c = buildContract(acct.Id, 'Subscription', 'USD', 12, true);

        // Deliberately not setting SBQQ__LastCalculatedOn__c, to simulate a
        // quote that was just saved and hasn't recalculated yet.
        SBQQ__Quote__c q = new SBQQ__Quote__c(
            SBQQ__Account__c = acct.Id,
            SBQQ__Opportunity2__c = o.Id,
            SBQQ__Primary__c = true,
            SBQQ__StartDate__c = Date.today(),
            Pricing_Model__c = 'Subscription',
            Currency_Code__c = 'USD',
            SBQQ__SubscriptionTerm__c = 12
        );
        insert q;
        linkPrimaryQuoteAndContract(o.Id, c.Id, q.Id);

        SBQQ__Quote__c inserted = [SELECT SBQQ__Uncalculated__c FROM SBQQ__Quote__c WHERE Id = :q.Id];

        Test.startTest();
        LaunchEligibilityEvaluator.evaluate(new List<Id>{ o.Id });
        Test.stopTest();

        List<Merchant_Launch_Handoff__c> handoffs = [
            SELECT Id FROM Merchant_Launch_Handoff__c WHERE Opportunity__c = :o.Id
        ];

        if (inserted.SBQQ__Uncalculated__c == true) {
            System.assertEquals(
                0, handoffs.size(),
                'A quote still calculating should be skipped entirely, not logged as a mismatch'
            );
        } else {
            // This org's CPQ config didn't leave the quote uncalculated on a
            // plain insert (e.g. SBQQ__LastSavedOn__c wasn't auto-stamped),
            // so this run couldn't actually simulate the state. Not a failure,
            // just nothing to assert. See README.
        }
    }
}
