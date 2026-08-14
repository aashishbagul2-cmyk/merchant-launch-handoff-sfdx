/**
 * Scheduled safety net for handoffs stuck in Event_Published or
 * Downstream_Failed past an SLA window: retries up to MAX_ATTEMPTS, then
 * opens a Case for manual review instead of retrying forever.
 *
 * The retry logic is factored into processStuckHandoffs(cutoff) rather than
 * hardcoding "now minus 15 minutes" inline, specifically so it's unit
 * testable: Apex tests can't backdate LastModifiedDate on freshly inserted
 * records, so tests pass a cutoff in the near future instead.
 */
global class HandoffRecoverySweeper implements Schedulable {

    private static final Integer MAX_ATTEMPTS = 3;
    private static final Integer SLA_MINUTES = 15;

    global void execute(SchedulableContext ctx) {
        processStuckHandoffs(DateTime.now().addMinutes(-SLA_MINUTES));
    }

    public static void processStuckHandoffs(DateTime cutoff) {
        List<Merchant_Launch_Handoff__c> stuck = [
            SELECT Id, Attempt_Count__c, Status__c, Opportunity__c
            FROM Merchant_Launch_Handoff__c
            WHERE Status__c IN ('Event_Published', 'Downstream_Failed')
            AND LastModifiedDate < :cutoff
            LIMIT 200
        ];
        if (stuck.isEmpty()) {
            return;
        }

        List<Merchant_Launch_Handoff__c> toRetry = new List<Merchant_Launch_Handoff__c>();
        List<Case> casesToCreate = new List<Case>();
        List<Handoff_Event_Log__c> logs = new List<Handoff_Event_Log__c>();

        for (Merchant_Launch_Handoff__c h : stuck) {
            if (h.Attempt_Count__c >= MAX_ATTEMPTS) {
                casesToCreate.add(new Case(
                    Subject = 'Merchant launch handoff needs manual review: ' + h.Id,
                    Description = 'Handoff ' + h.Id + ' exceeded the automated retry cap (' + MAX_ATTEMPTS + ' attempts).',
                    Status = 'New',
                    Priority = 'High'
                ));
                logs.add(new Handoff_Event_Log__c(
                    Handoff__c = h.Id,
                    Action__c = 'Retry cap reached - Case created',
                    Automated__c = true
                ));
            } else {
                h.Attempt_Count__c = (h.Attempt_Count__c == null ? 0 : h.Attempt_Count__c) + 1;
                toRetry.add(h);
                logs.add(new Handoff_Event_Log__c(
                    Handoff__c = h.Id,
                    Action__c = 'Automated retry attempt ' + String.valueOf(h.Attempt_Count__c),
                    Automated__c = true
                ));
            }
        }

        if (!toRetry.isEmpty()) {
            update toRetry;
            republishEvents(toRetry);
        }
        if (!casesToCreate.isEmpty()) {
            insert casesToCreate;
        }
        if (!logs.isEmpty()) {
            insert logs;
        }
    }

    private static void republishEvents(List<Merchant_Launch_Handoff__c> handoffs) {
        List<Merchant_Launch_Eligible__e> events = new List<Merchant_Launch_Eligible__e>();
        for (Merchant_Launch_Handoff__c h : handoffs) {
            events.add(new Merchant_Launch_Eligible__e(
                Handoff_Id__c = h.Id,
                Opportunity_Id__c = h.Opportunity__c
            ));
        }
        EventBus.publish(events);
    }
}
