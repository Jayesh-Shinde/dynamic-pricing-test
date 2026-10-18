# Dynamic-pricing Assignment

This is a readme file for Dynamic pricing assignment.
This Assignment include a dynamic pricing endpoint, a redis instance and a upstream dynamic pricing model.

## Build, test and run

### Steup

For this assignment to run only Docker and Docker Compose is needed. Ruby does not need to be installed locally.

### Location

The app is at `dynamic-pricing/` along with respective docker compose file. So all commands need to be run from there.

### Start

To start the project run below command:

```sh
docker compose up -d --build
```

It starts three services:

1. `rate-api`: upstream dynamic pricing model, runs on port 8080.
2. `redis`: this is newly added for caching purpose etc. (more on it in the design section), runs on port 6379.
3. `interview-dev`: this is our rails app, depends on both of above services and runs on port 3000.

### Test

```sh
docker compose exec interview-dev ./bin/rails test
```

Current stats are 61 runs, 183 assertions, 0 failures.

Test uses the real redis on db 1 while app uses db 0. It is flushed before every test. To simulate actual locks and lua script compare and delete, needed actual redis in tests. Fake would not simulate it.

### Samples

Try sample curl:

```sh
curl --location 'http://localhost:3000/api/v1/pricing?period=Winter&hotel=FloatingPointResort&room=RestfulKing'
```

Success response:

```json
{
  "rate": 62500
}
```

Invalid param would result in below 400 status code response. Example by passing room as `RestfulKin`:

```json
{
  "error": "Invalid room. Must be one of: SingletonRoom, BooleanTwin, RestfulKing",
  "code": "invalid_params"
}
```

If in case upstream model or cache is not available then sample response would be as below. To try it, stop rate-api and flush redis `docker compose exec redis redis-cli FLUSHDB`
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

For rails app below notable env variables are configured:

- `RATE_API_URL=http://rate-api:8080`
- `REDIS_URL=redis://redis:6379/0`
- `RATE_API_TIMEOUT_SECONDS`: we can set for app from env while calling upstream, default is 3.
- `RATE_API_TOKEN`: it can be passed from env with default fallback to hard-coded secret.

### Constraints

The rate-api has a quota of 1000 calls/day and resets when you restart its container. Failed requests (this includes timeouts) are also counted in quota. Following command is for reference:

```sh
docker compose restart rate-api
```

## The problem and the quota math

### Requirements :

The rates returned from our api should not be older than 5 min. Our API gets at least 10000 requests/day. So it makes sence to serve stale data upto 5 min in case upstream is slow or failing.

### The core tension :

10000 user requests/day against 1000 upstream calls/day. So most requests have to be served from a cache, and only refreshes uses the quota of upstream, not actual user requests.

### Option 1 :

cache each key separately (5 min TTL). so for 36 keys \* 288 five-minute windows(in 24her) = 10368 calls/day.
This goes beyond our quota

### Option 2 :

one batch call for all 36 keys: one call costs one quota unit
24hr has 1440 mins
So on a high level
Refresh after 3 min: at most 1440 / 3 = 480 refreshes/day.
The measured success rate is around 73% (measured in own one local Test). Out of 100 calls, about 73 succeed. So 73 successful refreshes cost 100 calls, which is 100 / 73 = 1.38 calls per refresh. That's 480 × 1.38 = 660 attempts/day. Under 1000.

### Why always refresh the whole table :

If only stale keys were refreshed, the keys would end up expiring at different times and the call count quota against upstream would be exausted.

### Why Redis and not in-memory :

With 3 app instances each keeping its own cache, it's 3 \* 360 = 1080 calls/day, over the quota. A shared cache and a shared lock keep it to one refresher for all instances.

### Worst case, a full-day upstream outage :

The cooldown is capped at 2 min, with one attempt per refresh, so 720 calls/day. That stays under the quota even with no successes.
