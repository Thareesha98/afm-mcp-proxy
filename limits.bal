import ballerina/time;

isolated class RateLimiter {
    private final decimal perSecond;
    private final decimal burst;
    private decimal tokens;
    private decimal? updatedAt = ();

    isolated function init(int requestsPerMinute, int burst) {
        self.perSecond = <decimal>requestsPerMinute / 60;
        self.burst = <decimal>burst;
        self.tokens = self.burst;
    }

    isolated function take(decimal? at = ()) returns boolean {
        lock {
            decimal now = at ?: time:monotonicNow();
            decimal? last = self.updatedAt;
            decimal elapsed = last is decimal ? now - last : 0d;
            decimal available = decimal:min(self.burst, self.tokens + elapsed * self.perSecond);
            boolean allowed = available >= 1d;
            self.tokens = allowed ? available - 1d : available;
            self.updatedAt = now;
            return allowed;
        }
    }
}
