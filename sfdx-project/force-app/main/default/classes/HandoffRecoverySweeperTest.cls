/**
 * Covers the fourth required test scenario: downstream failure and retry.
 * Deliberately avoids touching CPQ/Contract, this exercises the sweeper in
 * isolation so it does not depend on any org-specific CPQ configuration.
 */
@IsTest
private class HandoffRecoverySweeperTest {

    private static Merchant_Launch_Handoff__c buildHandoff(String status, Decimal attemptCount) {
        Account a = new Account(Name = 'Sweeper Test Merchant ' + String.valueOf(Math.random()));
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Sweeper Test Opportunity',
            AccountId = a.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today()
        );
        insert o;

        Merchant_Launch_Handoff__c h = new Merchant_Launch_Handoff__c(
            Opportunity__c = o.Id,
            Idempotency_Key__c = 'sweeper-test-' + String.valueOf(Math.random()),
            Status__c = status,
            Attempt_Count__c = attemptCount
        );
        insert h;
        return h;
    }

    @IsTest
    static void stuckHandoffIsRetried() {
        Merchant_Launch_Handoff__c h = buildHandoff('Downstream_Failed', 0);

        Test.startTest();
        // Cutoff set in the near future so this freshly-inserted record
        // counts as "stuck" without needing to wait real elapsed time.
        HandoffRecoverySweeper.processStuckHandoffs(DateTime.now().addMinutes(1));
        Test.stopTest();

        Merchant_Launch_Handoff__c updated = [
            SELECT Attempt_Count__c, Status__c FROM Merchant_Launch_Handoff__c WHERE Id = :h.Id
        ];
        System.assertEquals(1, updated.Attempt_Count__c, 'Sweeper should increment the attempt count on retry');

        List<Case> cases = [SELECT Id FROM Case];
        System.assertEquals(0, cases.size(), 'Should not open a case before the retry cap is reached');
    }

    @IsTest
    static void retryCapOpensACase() {
        Merchant_Launch_Handoff__c h = buildHandoff('Downstream_Failed', 3); // already at the cap

        Test.startTest();
        HandoffRecoverySweeper.processStuckHandoffs(DateTime.now().addMinutes(1));
        Test.stopTest();

        List<Case> cases = [SELECT Id, Subject FROM Case];
        System.assertEquals(1, cases.size(), 'Should open exactly one case once the retry cap is reached');

        Merchant_Launch_Handoff__c updated = [SELECT Attempt_Count__c FROM Merchant_Launch_Handoff__c WHERE Id = :h.Id];
        System.assertEquals(3, updated.Attempt_Count__c, 'Attempt count should not increment further once capped');
    }

    @IsTest
    static void scheduledExecuteRunsWithoutError() {
        buildHandoff('Event_Published', 0);

        Test.startTest();
        System.schedule('Handoff Recovery Sweeper Test', '0 0 * * * ?', new HandoffRecoverySweeper());
        Test.stopTest();
        // No separate assertion here beyond "the Schedulable wrapper compiles
        // and runs without throwing" -- the actual retry behavior is already
        // covered directly by processStuckHandoffs() above.
    }
}
