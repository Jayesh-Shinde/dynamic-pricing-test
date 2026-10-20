# Design

## Components

![Components](components.svg)

- **Controller**: Checks the params against the 36 allowed combinations. Returns the rate, a 400 for bad params, or a 503 with `Retry-After`.
- **PricingService**: Decides what to do for each request: serve the cached table, start a refresh, or wait for another request that is refreshing.
- **RateCache**: The class that talks to Redis. It reads and writes the rate table, and handles the lock, the cooldown and the failure counter.
- **RateRefresher**: Takes the lock, makes one upstream call then saves the new table or starts a cooldown if the call failed.
- **RateApiClient**: Sends one batch request for all 36 combinations with a 3s timeout and checks the response before it is used.
- **Redis**: Holds the rate table, the lock, the cooldown and the failure counter. In production, several app instances share this one Redis so there is one cache and one refresher across all of them.
- **rate-api**: The external pricing model. It allows 1000 calls a day per token and failed calls count too.
