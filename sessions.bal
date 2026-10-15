import ballerina/cache;
import ballerina/uuid;

const string SESSION_HEADER = "x-choreo-correlation-id";
const string SESSION_PREFIX = "afm-";

type Admission record {|
    boolean allowed;
    string? issued;
|};

isolated class Sessions {
    private final cache:Cache buckets;
    private final RateLimiter minting;
    private final RateLimiter anonymous;
    private final int requestsPerMinute;
    private final int burst;
    private final decimal lifetimeSeconds;

    isolated function init(int requestsPerMinute, int burst, int newPerMinute, int newBurst, int capacity, int lifetimeSeconds) {
        self.buckets = new ({capacity, evictionFactor: 0.5 / <float>capacity});
        self.minting = new (newPerMinute, newBurst);
        self.anonymous = new (requestsPerMinute, burst);
        self.requestsPerMinute = requestsPerMinute;
        self.burst = burst;
        self.lifetimeSeconds = <decimal>lifetimeSeconds;
    }

    isolated function admit(string? presented) returns Admission {
        lock {
            if presented is string {
                any|cache:Error found = self.buckets.get(presented);
                if found is RateLimiter {
                    return {allowed: found.take(), issued: ()};
                }
            }
            if self.minting.take() {
                string id = SESSION_PREFIX + uuid:createRandomUuid();
                RateLimiter bucket = new (self.requestsPerMinute, self.burst);
                cache:Error? stored = self.buckets.put(id, bucket, self.lifetimeSeconds);
                if stored is () {
                    return {allowed: bucket.take(), issued: id};
                }
            }
            return {allowed: self.anonymous.take(), issued: ()};
        }
    }

    isolated function size() returns int {
        lock {
            return self.buckets.size();
        }
    }
}
