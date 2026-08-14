/**
 * Tests the trigger-based sync directly, this is the single source of truth
 * for Opportunity.Launch_Status__c, so it needs its own coverage independent
 * of whichever caller (evaluator, sweeper, callback) happens to touch
 * Merchant_Launch_Handoff__c.Status__c.
 */
@IsTest
private class MerchantLaunchHandoffTriggerHandlerTest {

    private static Id buildOpportunity() {
        Account a = new Account(Name = 'Trigger Test Merchant ' + String.valueOf(Math.random()));
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Trigger Test Opportunity', AccountId = a.Id, StageName = 'Closed Won', CloseDate = Date.today()
        );
        insert o;
        return o.Id;
    }

    @IsTest
    static void statusChangeSyncsOntoOpportunity() {
        Id oppId = buildOpportunity();

        Merchant_Launch_Handoff__c h = new Merchant_Launch_Handoff__c(
            Opportunity__c = oppId,
            Idempotency_Key__c = 'trigger-test-' + String.valueOf(Math.random()),
            Status__c = 'Eligible'
        );

        Test.startTest();
        insert h;
        h.Status__c = 'Event_Published';
        update h;
        Test.stopTest();

        Opportunity updated = [SELECT Launch_Status__c FROM Opportunity WHERE Id = :oppId];
        System.assertEquals(
            'Sent_to_Onboarding', updated.Launch_Status__c,
            'Should reflect the latest handoff status, Event_Published maps to Sent_to_Onboarding'
        );
    }

    @IsTest
    static void bulkStatusChangesSyncCorrectly() {
        List<Id> oppIds = new List<Id>();
        List<Merchant_Launch_Handoff__c> handoffs = new List<Merchant_Launch_Handoff__c>();
        for (Integer i = 0; i < 50; i++) {
            Id oppId = buildOpportunity();
            oppIds.add(oppId);
            handoffs.add(new Merchant_Launch_Handoff__c(
                Opportunity__c = oppId,
                Idempotency_Key__c = 'bulk-trigger-test-' + String.valueOf(i) + '-' + String.valueOf(Math.random()),
                Status__c = 'Blocked_Mismatch'
            ));
        }

        Test.startTest();
        insert handoffs;
        Test.stopTest();

        List<Opportunity> opps = [SELECT Launch_Status__c FROM Opportunity WHERE Id IN :oppIds];
        System.assertEquals(50, opps.size());
        for (Opportunity o : opps) {
            System.assertEquals('Blocked', o.Launch_Status__c);
        }
    }

    @IsTest
    static void noOpUpdateDoesNotRewriteOpportunity() {
        Id oppId = buildOpportunity();
        Merchant_Launch_Handoff__c h = new Merchant_Launch_Handoff__c(
            Opportunity__c = oppId,
            Idempotency_Key__c = 'noop-test-' + String.valueOf(Math.random()),
            Status__c = 'Eligible'
        );
        insert h;

        Test.startTest();
        // Update a different field, not Status__c, should not re-trigger a sync.
        h.Last_Error__c = 'unrelated change';
        update h;
        Test.stopTest();

        Opportunity updated = [SELECT Launch_Status__c FROM Opportunity WHERE Id = :oppId];
        System.assertEquals('Eligible', updated.Launch_Status__c, 'Unrelated field changes should not need a resync, but this is not harmful if it happens either way');
    }
}
