public with sharing class MerchantLaunchHandoffTriggerHandler {

    // Handoff Status__c -> Opportunity Launch_Status__c. Kept as an explicit
    // map rather than scattered if/else so the mapping is one place to read,
    // not something to reverse-engineer from call sites.
    private static final Map<String, String> STATUS_MAP = new Map<String, String>{
        'Pending' => 'Pending',
        'Eligible' => 'Eligible',
        'Event_Published' => 'Sent_to_Onboarding',
        'Downstream_Accepted' => 'Sent_to_Onboarding',
        'Downstream_Failed' => 'Failed',
        'Launched' => 'Launched',
        'Blocked_Mismatch' => 'Blocked'
    };

    public static void syncOpportunityLaunchStatus(List<Merchant_Launch_Handoff__c> handoffs) {
        Map<Id, Opportunity> toUpdate = new Map<Id, Opportunity>();
        for (Merchant_Launch_Handoff__c h : handoffs) {
            String mapped = STATUS_MAP.get(h.Status__c);
            if (mapped != null) {
                toUpdate.put(h.Opportunity__c, new Opportunity(Id = h.Opportunity__c, Launch_Status__c = mapped));
            }
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate.values();
        }
    }
}
