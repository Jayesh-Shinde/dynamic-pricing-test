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

Each key gets its own 5 min TTL. For 36 keys × 288 five-minute windows in 24 hours, that's up to 10368 calls/day. Way over the quota.

### Option 2: one batch call for all 36 keys

One call fetches all 36 keys and costs one quota unit.

A day has 1440 minutes. If we refresh after 3 minutes, that's at most 1440 / 3 = 480 refreshes/day. It's max 480 because a refresh only happens when a request comes in so if no requests comes in quiet hours then no refresh call to upstream.

Not every call succeeds. I ran two local tests of about 1000 calls each, and both came out around 73% success. So 73 successful refreshes cost about 100 calls, which is 100 / 73 = 1.38 calls per refresh. That gives 480 × 1.38 = 660 attempts/day, under 1000.

Why 3 minutes and not 5? Refreshing at 3 minutes leaves a 2-minute buffer. If a refresh fails, the cached table is still under 5 minutes old and can still be served while we retry. If we waited until exactly 5 minutes, any failed refresh would mean the user gets an error.

### Why always refresh the whole table

If we refreshed only the stale keys, they would slowly drift apart and expire at different times. Each one would then need its own call, and we'd be sliding back toward Option 1 and its 10000+ calls. Refreshing all 36 together keeps them on the same clock, so one call is always enough.

### Why Redis and not in-memory

Say we run 3 app instances and each keeps its own cache. That's 3 × 480 = 1440 refreshes/day, over the quota. A shared cache and one shared lock keep it to a single refresher across all instances.

### Worst case: a full-day upstream outage

After a failed refresh, the cooldown starts at 5 seconds and increases with each failure. Capped at 2 minutes. Each refresh makes only one attempt, so a full day of failures costs roughly 730 calls. That stays under the quota.

## Section 3: Design

Diagrams are in [docs/design.md](docs/design.md).

### Components

Request path: `Controller` -> `PricingService` -> `RateCache` (Redis) -> `RateRefresher` -> `RateApiClient` -> `rate-api`.

- **`RateCatalog`**: The 36 allowed combinations. The controller validates against it and the refresher sends this same list. As both use the same list, the batch can never miss a key for valid input.
- **`RateCache`**: It is the only class that touches Redis, so swapping the store means changing one class.

### Request flow

1. Invalid params -> 400 right away. No Redis call, no upstream call, no quota used.
2. Table ≤ 3 min old -> serve it.
3. Table 3–5 min old -> always serve it. The only factor is which request also triggers a refresh
   - cooldown active -> no refresh
   - lock won -> this request gets to refresh and then serves
   - lock lost -> serve straight away, since someone else is already refreshing
4. Table missing or > 5 min -> nothing valid to serve
   - cooldown active -> 503 immediately
   - lock won -> refresh. Serve on success, 503 on failure
   - lock lost -> poll Redis every 200 ms for up to 4s waiting for the winner.
     If the cache is filled then serve it otherwise 503.
     A waiting request never calls upstream and never retries the lock, because if the winner failed, the cooldown is already set, so a retry would be blocked anyway.
5. Serve-time check: every path checks the age again right before responding.
   Example: a table that was 4m58s old when a 3s refresh started is 5m01s old by the time it would be served. That gets an error. Never send stale data.

### Inside a refresh

1. One batch call with all 36 keys. One attempt only, no retry inside the refresh. The 3–5 min window already gives a window for retries.
2. `fetched_at` is recorded before the call is sent, so the time the fetch takes counts toward the table's age and is taken off its Redis expiry.
3. The response is all-or-nothing. It's valid only if `rates` exists and every rate is an integer or a numeric string (converted to an integer). Anything else is a failure and is never cached.

### Redis keys

- **Table**: All 36 rates + `fetched_at`, stored as one JSON value. The Redis expiry is set to the time left until 5 min.
- **Lock**: Decides who refreshes now. `SET NX PX` 10s with a random token. The lock is released only by its owner, so a lock that expired and was taken by another request is never deleted by mistake.
- **Cooldown**: Decides whether anyone should try now. 5s × consecutive failures, capped at 2 min; 1 h after a 429. Reset on success
- **Failure counter**: Counts consecutive failures. Reset on success. 10 min TTL so a stale count clears itself.

The lock and the cooldown are separate on purpose: the lock answers who gets to refresh, the cooldown answers should anyone try now.
If there is no cooldown then every request would win lock and make upstream call. With 10k requests a day, quota would be gone quickly. Upon outage recovery there is no quota left. Cooldown avoids it by spacing attempts.

### Error responses

One flat shape for every error: `{ "error": message, "code": ... }`. It's flat so the scaffold's 400 tests and any client that reads `error` as a string keep working.

Codes: `invalid_params` (400), `rates_unavailable`, `upstream_quota_exhausted`, `cache_unavailable` (all 503 + `Retry-After`).

**Why 503 and not 429 for quota**: The 429 is about our upstream token's quota, not the caller's request rate, so the caller gets a 503.

### Logging

- One `rate_refresh` JSON line per upstream attempt: `outcome`, `http_status`, `latency_ms`. Counting these lines gives the quota usage.
- One `pricing_request` JSON line per user request.

## Section 4: Failure behaviour

- If the cached table is still ≤ 5 min old, it is served and the user never sees the failure. Failed responses are never cached.
- Every 503 has a `Retry-After` header: the cooldown time left, or 5s.
- Upstream slow (> 3s), down, 5xx, error body, bad/null rates -> 503 `rates_unavailable`, cooldown 5s × failures (cap 2 min)
- Upstream 429 -> 503 `upstream_quota_exhausted`, cooldown 1 h
- Upstream 400 (a bug on our side) -> 503 `rates_unavailable`, logged at error level
- Redis down -> 503 `cache_unavailable`, no upstream call
- Invalid params -> 400 `invalid_params`

## Section 5: Assumptions

- **When the 5 minutes start**: from just before the upstream call is sent (`fetched_at`), not from when the response arrives, so ex: it took 2s to fetch response then ttl would be 4m58s.
- **Stale vs error**: when nothing ≤ 5 min old is available, the user gets a 503, never an older rate. The requirement says no older than 5 minutes.
- **Rate type**: upstream sometimes sends a number and sometimes a numeric string. Our API always returns an integer as consistent type. Anything else like null, decimal, negative, text makes the whole response invalid.
- **Fixed catalog**: the 36 combinations are fixed, which is what makes a full table refresh in one call possible. If the catalog grew large, this design would need to change.
- **Traffic shape**: 10000 requests/day is roughly one every 9s, so refreshing on demand gets more chances inside the 3–5 min window.
- **Quota reset window**: unknown in production (in dev the container resets on restart). After a 429 I wait 1 h before trying again. This is a guess, set as a default in `start_quota_cooldown`, not an env setting.
- **Failed calls cost quota**: measured during local test. Timeouts, 500s and error bodies were all charged against the 1000. That is why each refresh makes one attempt only.
- **Rates are not stable per key**: the same key returns different rates in separate calls. A cached value is one sample from the model, which I took to be acceptable for up to 5 min.

## Section 6: Known weaknesses and next steps

- Redis is a single point of failure. If it's down we fail closed and every request gets a 503.

  Next: in production, Redis with a replica and automatic failover (ex: AWS ElastiCache Multi AZ). Optionally, while Redis is being restored, fall back to an in-memory copy of the last table, served only while it's under 5 min old.

- The design depends on a small, fixed combinations. A full-table refresh works because there are only 36 keys. With ex: 10000+ keys, one batch call wouldn't fit and refreshing everything would waste calls.

  Next: refresh only recently requested keys in batches or raise the upstream quota; or agree a longer max age with product.

- There is no count of upstream calls per day. We only react after upstream sends a 429. The reset window in production is unknown and the 1 h cooldown after a 429 is a guess.

  Next: alert when daily `rate_refresh` attempts pass about 800 (80%), so someone can act (like ask for limit raise) before the limit. Once the reset window is known a counter stops calls automatically and a configurable cooldown becomes possible.

- Waiting requests hold a Puma thread. When the cache is empty, losers sleep and poll Redis for up to 4s, and each one blocks a thread (5 per process). At about one request every 9s this is fine, but a burst at an empty cache could use up all the threads.

  Next: more Puma threads/processes, or let waiting requests return 503 with a short `Retry-After` instead of waiting.

- Logs only, no metrics or alerts. The JSON lines make counting possible, but nothing watches them.

  Next: metrics for refresh success rate, cache age and 503 rate. Alert on any `bad_request` (our bug), on a 429.

- The upstream token has a hard-coded fallback. `RATE_API_TOKEN` falls back to a secret in the code. That was fine for the assignment, but in production it should be read from the parameter store/secret manager. No default.

## Section 7: AI usage

- Context: I am a Node.js/TypeScript backend developer, new to Ruby.
- My part:
  - Upstream experiments: two runs of about 1000 calls each and every measured number.
  - The design and its trade-offs: whole-table refresh, Redis, lock + cooldown, 3/5 min windows, fail closed, 503 instead of stale data.
  - Reviewing every code chunk before accepting it, and making every commit.
  - Writing the README myself. Claude formatted the Markdown and reviewed it for accuracy.
- Claude Code part:
  - Wrote the Ruby in small chunks (one method at a time), explained with Node analogies.
  - Reviewed the design. I accepted 4 changes: serve time age check, real Redis in tests, 200ms polling, integer rates.
  - Suggested mutation checks (break the code on purpose, confirm a test fails).
- What I changed or rejected:
  - Dropped the daily upstream-call counter: without the reset window it does not help.
  - Flat error shape instead of nested, so the scaffold tests and existing clients keep working.
  - Kept param validation in the controller instead of moving it into the service.
  - Rejected a 50-call quota reserve in favour of an alert at 80%. Left out a database fallback (correlated outages).
  - Spotted the lock TTL fix.
- Workflow: I designed and refined the solution -> Claude Code wrote the code chunk by chunk -> I reviewed each chunk through discussion, ran the tests and committed.
