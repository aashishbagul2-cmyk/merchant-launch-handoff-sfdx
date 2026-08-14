/**
 * Tests the requeue-once path added in response to a real gap: the design
 * doc used to claim a lock failure "requeues itself once," but the code
 * only re-threw the exception. This confirms the actual Queueable retry
 * works, not that real row-lock contention can be simulated, single-threaded
 * Apex tests can't produce genuine concurrent lock contention, so this tests
 * the requeue mechanism in isolation instead.
 */
@IsTest
private class RetryEligibilityEvaluatorTest {

    private static Id buildEligibleOpportunity() {
        Account a = new Account(Name = 'Retry Test Merchant ' + String.valueOf(Math.random()));
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Retry Test Opportunity', AccountId = a.Id, StageName = 'Closed Won', CloseDate = Date.today()
        );
        insert o;
        Contract c = new Contract(
            AccountId = a.Id, Pricing_Model__c = 'Subscription', Currency_Code__c = 'USD',
            ContractTerm = 12, Approved_Terms_Matched__c = true, Contract_Version__c = 1
        );
        insert c;
        c.Status = 'Activated';
        update c;
        SBQQ__Quote__c q = new SBQQ__Quote__c(
            SBQQ__Account__c = a.Id, SBQQ__Opportunity2__c = o.Id, SBQQ__Primary__c = true,
            SBQQ__StartDate__c = Date.today(), Pricing_Model__c = 'Subscription',
            Currency_Code__c = 'USD', SBQQ__SubscriptionTerm__c = 12,
            SBQQ__LastCalculatedOn__c = System.now().addMinutes(10)
        );
        insert q;
        update new Opportunity(Id = o.Id, Primary_Contract__c = c.Id, SBQQ__PrimaryQuote__c = q.Id);
        return o.Id;
    }

    @IsTest
    static void retryQueueableCompletesTheEvaluation() {
        Id oppId = buildEligibleOpportunity();

        Test.startTest();
        // Simulates what LaunchEligibilityEvaluator's catch block does after
        // losing a row lock: enqueue the retry with isRetry = true.
        System.enqueueJob(new RetryEligibilityEvaluator(new List<Id>{ oppId }), 1);
        Test.stopTest(); // delay is ignored under test, job runs here

        Merchant_Launch_Handoff__c handoff = [
            SELECT Status__c FROM Merchant_Launch_Handoff__c WHERE Opportunity__c = :oppId
        ];
        System.assertEquals(
            'Event_Published', handoff.Status__c,
            'Retry should complete the evaluation normally once the lock is gone'
        );
    }
}
