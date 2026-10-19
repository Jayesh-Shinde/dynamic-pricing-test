# Dynamic Pricing Assignment

This is the README for the dynamic pricing assignment.
The assignment includes a dynamic pricing endpoint, a Redis instance and an upstream dynamic pricing model.

## Section 1: Build, test and run

### Setup

Only Docker and Docker Compose are needed to run this assignment. Ruby does not need to be installed locally.

### Location

The app is in `dynamic-pricing/` along with its Docker Compose file, so all commands need to be run from there.

### Start

To start the project, run:

```sh
docker compose up -d --build
```

It starts three services:

1. `rate-api`: the upstream dynamic pricing model, runs on port 8080.
2. `redis`: newly added for caching, the refresh lock and the cooldown (more on it in the design section), runs on port 6379.
3. `interview-dev`: our Rails app, depends on both of the above and runs on port 3000.

### Test

```sh
docker compose exec interview-dev ./bin/rails test
```

Current stats: 61 runs, 183 assertions, 0 failures.

Tests use the real Redis on db 1, while the app uses db 0. It is flushed before every test. I needed a real Redis in tests to exercise the actual locks and the Lua compare-and-delete script. A fake would not simulate them.

### Samples

Try a sample curl:

```sh
curl --location 'http://localhost:3000/api/v1/pricing?period=Winter&hotel=FloatingPointResort&room=RestfulKing'
```

Success response:

```json
{
  "rate": 62500
}
```

An invalid param gives a 400 response like the one below. Example with room passed as `RestfulKin`:

```json
{
  "error": "Invalid room. Must be one of: SingletonRoom, BooleanTwin, RestfulKing",
  "code": "invalid_params"
}
```

If the upstream model or the cache is not available, the response is a 503 with a `Retry-After` header and a body like the one below. To try it, stop rate-api and flush Redis: `docker compose exec redis redis-cli FLUSHDB`.
Upstream down gives `rates_unavailable`. Redis down gives `cache_unavailable`.

```json
{
  "error": "Fresh rates are temporarily unavailable. Please retry shortly.",
  "code": "rates_unavailable"
}
```

### Allowed values

4 periods (Summer, Autumn, Winter, Spring), 3 hotels (FloatingPointResort, GitawayHotel, RecursionRetreat) and 3 rooms (SingletonRoom, BooleanTwin, RestfulKing), giving 36 distinct combinations.

### Env variables

Notable env variables for the Rails app:

- `RATE_API_URL=http://rate-api:8080`
- `REDIS_URL=redis://redis:6379/0`
- `RATE_API_TIMEOUT_SECONDS`: timeout for calls to the upstream, default is 3.
- `RATE_API_TOKEN`: can be passed from env, falls back to the hard-coded secret.

### Constraints

The rate-api has a quota of 1000 calls/day, which resets when you restart its container. Failed requests (including timeouts) also count against the quota. To reset it:

```sh
docker compose restart rate-api
```

## Section 2: The problem and the quota math

### Requirements

1. A rate is never more than 5 minutes old.
2. Handle at least 10000 requests a day on one token.
3. Behave sensibly when the upstream is slow or failing, with descriptive errors.

### The core tension

10000 user requests/day against 1000 upstream calls/day. So most requests have to be served from a cache. Only refreshes use the upstream quota, not the user requests themselves.

### Option 1: cache each key separately

Each key gets its own 5 min TTL. For 36 keys × 288 five-minute windows in 24 hours, that's up to 10,368 calls/day. Way over the quota.

### Option 2: one batch call for all 36 keys

One call fetches all 36 keys and costs one quota unit.

A day has 1,440 minutes. If we refresh after 3 minutes, that's at most 1440 / 3 = 480 refreshes/day. It's max 480 because a refresh only happens when a request comes in so if no requests comes in quiet hours then cost less.

Not every call succeeds. I ran two local tests of about 1000 calls each, and both came out around 73% success. So 73 successful refreshes cost about 100 calls, which is 100 / 73 = 1.38 calls per refresh. That gives 480 × 1.38 = 660 attempts/day, under 1,000.

Why 3 minutes and not 5? Refreshing at 3 minutes leaves a 2-minute buffer. If a refresh fails, the cached table is still under 5 minutes old and can still be served while we retry. If we waited until exactly 5 minutes, any failed refresh would mean the user gets an error.

### Why always refresh the whole table

If we refreshed only the stale keys, they would slowly drift apart and expire at different times. Each one would then need its own call, and we'd be sliding back toward Option 1 and its 10000+ calls. Refreshing all 36 together keeps them on the same clock, so one call is always enough.

### Why Redis and not in-memory

Say we run 3 app instances and each keeps its own cache. That's 3 × 480 = 1440 refreshes/day, over the quota. A shared cache and one shared lock keep it to a single refresher across all instances.

### Worst case: a full-day upstream outage

After a failed refresh, the cooldown starts at 5 seconds and increases with each failure. Capped at 2 minutes. Each refresh makes only one attempt, so a full day of failures costs roughly 730 calls. That stays under the quota.

## Section 3: Design

### Components

Request path: Controller → PricingService → RateCache (Redis) → RateRefresher → RateApiClient → rate-api.
RateCatalog: The 36 allowed combinations. The controller validates against it and the refresher sends same this list. As both use the same list, the batch can never miss a key for valid input.
RateCache: It is the only class that touches Redis, so swapping the store means changing one class.

### Request flow

1. Invalid params -> 400 right away. No Redis call, no upstream call, no quota used.
2. Table ≤ 3 min old -> serve it.
3. Table 3–5 min old -> always serve it. The only factor is which request also triggers a refresh
   . cooldown active -> no refresh
   . lock won -> this request gets to refresh and then serves
   . lock lost -> serve straight away, since someone else is already refreshing
4. Table missing or > 5 min -> nothing valid to serve
   . cooldown active -> 503 immediately
   . lock won -> refresh. Serve on success, 503 on failure.
   . lock lost -> poll Redis every 200 ms for up to 4s waiting for the winner. If the cache is filled then serve it otherwise 503.
   A waiting request never calls never retries the lock, because if the winner failed, the cooldown is already set, so a retry would be blocked anyway.
5. Serve-time check: every path checks the age again right before responding.
   Example: a table that was 4m58s old when a 3s refresh started is 5m01s old by the time it would be served. That gets an error never send stale data.

### Inside a refresh

1. One batch call with all 36 keys. One attempt only, no retry inside the refresh. The 3–5 min window already gives a window for retries.
2. Fetched_at is recorded before the call is sent so while setting ttl we can reduce the time taken to fetch.
3. The response is all-or-nothing. It's valid only if rates exists and every rate is an integer or a numeric string (converted to an integer). Anything else is a failure and is never cached.

### Redis keys

Table: All 36 rates + fetched_at, stored as one JSON value. The Redis expiry is set to the time left until 5 min.
Lock: Decides who refreshes now. SET NX PX 10s with a random token, The lock has a random token and is released only by its owner, so a lock that expired and was taken by another request is never deleted by mistake.
Cooldown: Decides whether anyone should try now. 5s × consecutive failures, capped at 2 min; 1 h after a 429. Reset on success
Failure: Counter Counts consecutive failures. Reset on success. 10 min TTL so a stale count clears itself.
The lock and the cooldown are separate on purpose: the lock answers who gets to refresh, the cooldown answers should anyone try now.
If there is no cooldown then every request would win lock and make upstream call. with 10k calls a day , quota would be gone quickly. Upon outage recovery there is no quota left. Cooldown avoids it by spanning attempts.

### Error responses

One flat shape for every error: { "error": message, "code": ... }. It's flat so the scaffold's 400 tests and any client that reads error as a string keep working.
Codes: invalid_params (400), rates_unavailable, upstream_quota_exhausted, cache_unavailable (all 503 + Retry-After).
Why 503 and not 429 for quota: The 429 is about our upstream token's quota, not the caller's request rate, so the caller gets a 503.

### Logging

One rate_refresh JSON line per upstream attempt: outcome, http_status, latency_ms. Counting these lines gives the quota usage. One pricing_request JSON line per user request.
