/**
 * Single source of truth for keeping Opportunity.Launch_Status__c in sync
 * with the handoff record. This exists specifically so the sync doesn't have
 * to be repeated at every call site that changes Merchant_Launch_Handoff__c.Status__c,
 * LaunchEligibilityEvaluator, HandoffRecoverySweeper, and the eventual Workato
 * REST callback all change status through normal DML, and this trigger reacts
 * to that DML however it happened, rather than each caller remembering to
 * push the value onto Opportunity itself.
 */
trigger MerchantLaunchHandoffTrigger on Merchant_Launch_Handoff__c (after insert, after update) {
    List<Merchant_Launch_Handoff__c> toSync = new List<Merchant_Launch_Handoff__c>();

    for (Merchant_Launch_Handoff__c h : Trigger.new) {
        Merchant_Launch_Handoff__c old = Trigger.isUpdate ? Trigger.oldMap.get(h.Id) : null;
        Boolean statusChanged = old == null || old.Status__c != h.Status__c;
        if (statusChanged && h.Opportunity__c != null) {
            toSync.add(h);
        }
    }

    if (!toSync.isEmpty()) {
        MerchantLaunchHandoffTriggerHandler.syncOpportunityLaunchStatus(toSync);
    }
}
