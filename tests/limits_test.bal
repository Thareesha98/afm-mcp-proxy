import ballerina/test;

const decimal BASE = 1000000000;

function countAllowed(RateLimiter limiter, decimal at, int attempts) returns int {
    int allowed = 0;
    foreach int i in 0 ..< attempts {
        if limiter.take(at) {
            allowed += 1;
        }
    }
    return allowed;
}

@test:Config
function testBurstIsAllowedThenRejected() {
    RateLimiter limiter = new (60, 3);
    test:assertEquals(countAllowed(limiter, BASE, 10), 3);
}

@test:Config
function testTokensRefillOverTime() {
    RateLimiter limiter = new (60, 3);
    test:assertEquals(countAllowed(limiter, BASE, 3), 3);
    test:assertFalse(limiter.take(BASE));
    test:assertTrue(limiter.take(BASE + 1));
    test:assertFalse(limiter.take(BASE + 1));
}

@test:Config
function testRefillFollowsTheConfiguredRate() {
    RateLimiter fast = new (120, 4);
    test:assertEquals(countAllowed(fast, BASE, 4), 4);
    test:assertTrue(fast.take(BASE + 0.5d));
    test:assertFalse(fast.take(BASE + 0.5d));
    RateLimiter slow = new (30, 1);
    test:assertTrue(slow.take(BASE));
    test:assertFalse(slow.take(BASE + 1));
    test:assertTrue(slow.take(BASE + 2));
}

@test:Config
function testRefillNeverExceedsBurst() {
    RateLimiter limiter = new (60, 3);
    test:assertEquals(countAllowed(limiter, BASE, 3), 3);
    test:assertEquals(countAllowed(limiter, BASE + 30, 10), 3);
}

@test:Config
function testRejectedRequestsKeepRefillProgress() {
    RateLimiter limiter = new (60, 1);
    test:assertTrue(limiter.take(BASE));
    test:assertFalse(limiter.take(BASE + 0.5d));
    test:assertFalse(limiter.take(BASE + 0.9d));
    test:assertTrue(limiter.take(BASE + 1));
}

@test:Config
function testConcurrentRequestsNeverExceedTheBurst() {
    RateLimiter limiter = new (1, 10);
    future<boolean>[] results = [];
    foreach int i in 0 ..< 200 {
        future<boolean> result = start limiter.take();
        results.push(result);
    }
    int allowed = 0;
    foreach future<boolean> result in results {
        boolean|error answer = wait result;
        if answer is true {
            allowed += 1;
        }
    }
    test:assertEquals(allowed, 10);
}
