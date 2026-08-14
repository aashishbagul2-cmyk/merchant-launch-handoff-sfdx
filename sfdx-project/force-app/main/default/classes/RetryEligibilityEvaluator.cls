/**
 * One-shot retry for LaunchEligibilityEvaluator when the initial attempt
 * loses a row lock to a concurrent transaction (a Workato Contract sync and
 * a rep saving the Opportunity landing close together). Enqueued directly
 * from LaunchEligibilityEvaluator's catch block, not meant to be called
 * standalone.
 */
public class RetryEligibilityEvaluator implements Queueable {

    private List<Id> opportunityIds;

    public RetryEligibilityEvaluator(List<Id> opportunityIds) {
        this.opportunityIds = opportunityIds;
    }

    public void execute(QueueableContext ctx) {
        // isRetry = true: if this attempt also hits a lock, it does not
        // requeue again. See the comment in LaunchEligibilityEvaluator for
        // why that's an accepted limitation rather than unbounded retry.
        LaunchEligibilityEvaluator.runEvaluation(opportunityIds, true);
    }
}
