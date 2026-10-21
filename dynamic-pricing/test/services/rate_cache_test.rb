require "test_helper"

class RateCacheTest < ActiveSupport::TestCase
  RATES = { RateCache.key_for("Summer", "FloatingPointResort", "SingletonRoom") => 56900 }.freeze

  setup do
    @cache = RateCache.new
  end

  # Empty Redis -> a miss (nil), not an error.
  test "read returns nil when nothing is cached" do
    assert_nil @cache.read
  end

  # Round trip: rates and fetched_at survive the JSON stored in Redis.
  test "write then read returns the same table" do
    fetched_at = Time.current.to_f

    assert @cache.write(rates: RATES, fetched_at:)

    table = @cache.read
    assert_equal RATES, table.rates
    assert_in_delta fetched_at, table.fetched_at, 0.001
    assert_equal 56900, table.rate_for("Summer", "FloatingPointResort", "SingletonRoom")
  end

  # Requirement: valid for 5 minutes. Exactly 5:00 is still valid; 5:01 is not.
  # travel_to only moves Ruby's clock, not Redis's, so the key is still in Redis
  # here: this proves our own age check works without the Redis expiry.
  test "a table exactly 5 minutes old is served, one second older is not" do
    freeze_time
    @cache.write(rates: RATES, fetched_at: Time.current.to_f)

    travel 5.minutes
    assert_not_nil @cache.read

    travel 1.second
    assert_nil @cache.read
  end

  # Data already 60s old gets 240s of Redis TTL, so Redis also drops it at the 5 min.
  test "Redis expiry is set to the remaining serve time" do
    @cache.write(rates: RATES, fetched_at: Time.current.to_f - 60)

    pttl_ms = REDIS_POOL.with { |redis| redis.pttl(RateCache::TABLE_KEY) }
    assert_in_delta 240_000, pttl_ms, 1_000
  end

  # Data older than 5 min is never stored.
  test "write stores nothing when the data is already too old" do
    assert_not @cache.write(rates: RATES, fetched_at: Time.current.to_f - 301)

    assert_nil REDIS_POOL.with { |redis| redis.get(RateCache::TABLE_KEY) }
  end

  # Bad result in Redis counts as empty, so the next request refreshes.
  test "a corrupt entry reads as a miss instead of raising" do
    [
      "not json",
      "[1, 2]",
      { rates: RATES }.to_json,
      { fetched_at: "yesterday", rates: RATES }.to_json
    ].each do |raw|
      REDIS_POOL.with { |redis| redis.set(RateCache::TABLE_KEY, raw) }
      assert_nil @cache.read, "expected nil for #{raw.inspect}"
    end
  end

  # SET NX: the second acquire gets nil, so only one refresher at a time.
  test "only one caller gets the lock at a time" do
    token = @cache.acquire_lock

    assert_not_nil token
    assert_nil @cache.acquire_lock
  end

  # Release frees the lock for the next refresh.
  test "the lock can be taken again after its owner releases it" do
    token = @cache.acquire_lock

    assert @cache.release_lock(token)
    assert_not_nil @cache.acquire_lock
  end

  # A slow holder whose lock expired must not delete the new holder's lock.
  test "releasing with the wrong token keeps the lock" do
    @cache.acquire_lock

    assert_not @cache.release_lock("someone-elses-token")
    assert_nil @cache.acquire_lock
  end

  # test the lock expires by itself.
  test "the lock expires by itself" do
    old_token = @cache.acquire_lock(ttl: 0.1.seconds)
    sleep 0.15

    new_token = @cache.acquire_lock
    assert_not_nil new_token
    assert_not @cache.release_lock(old_token)
    assert_nil @cache.acquire_lock, "the old holder must not have released the new lock"
  end

  # Clean Redis -> no cooldown, so the first refresh is allowed.
  test "there is no cooldown at the start" do
    assert_nil @cache.cooldown_remaining
  end

  # Backoff: 1st failure -> 5s cooldown, 2nd -> 10s.
  test "each consecutive failure lengthens the cooldown by 5 seconds" do
    assert_equal 5, @cache.record_failure
    assert_equal 5, @cache.cooldown_remaining

    assert_equal 10, @cache.record_failure
    assert_equal 10, @cache.cooldown_remaining
  end

  # Many failures still give at most 120s, so a full-day outage costs ~730 calls.
  test "the cooldown is capped at 2 minutes" do
    30.times { @cache.record_failure }

    assert_equal 120, @cache.record_failure
    assert_equal 120, @cache.cooldown_remaining
  end

  # After a success, the next failure starts again at 5s.
  test "a success resets the failure count" do
    3.times { @cache.record_failure }
    @cache.record_success

    assert_equal 5, @cache.record_failure
  end

  # A good refresh clears any running cooldown, so nobody waits for no reason.
  test "a success ends a running cooldown" do
    @cache.record_failure
    @cache.record_success

    assert_nil @cache.cooldown_remaining
    assert_nil @cache.cooldown_reason
  end

  # The counter has a 10 min TTL, so an old failure streak heals itself.
  test "the failure counter expires by itself" do
    @cache.record_failure

    ttl = REDIS_POOL.with { |redis| redis.ttl(RateCache::FAILURES_KEY) }
    assert_in_delta 600, ttl, 1
  end

  # Quota cooldown is 1 h (reset window unknown), not the short failure backoff.
  test "an upstream 429 starts a 1 hour cooldown" do
    @cache.start_quota_cooldown

    assert_equal 3600, @cache.cooldown_remaining
  end
end
