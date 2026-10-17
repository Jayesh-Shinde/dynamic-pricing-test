require "test_helper"

class RateCacheTest < ActiveSupport::TestCase
  RATES = { RateCache.key_for("Summer", "FloatingPointResort", "SingletonRoom") => 56900 }.freeze

  setup do
    @cache = RateCache.new
  end

  test "read returns nil when nothing is cached" do
    assert_nil @cache.read
  end

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

  test "Redis expiry is set to the remaining serve time" do
    @cache.write(rates: RATES, fetched_at: Time.current.to_f - 60)

    pttl_ms = REDIS_POOL.with { |redis| redis.pttl(RateCache::TABLE_KEY) }
    assert_in_delta 240_000, pttl_ms, 1_000
  end

  test "write stores nothing when the data is already too old" do
    assert_not @cache.write(rates: RATES, fetched_at: Time.current.to_f - 301)

    assert_nil REDIS_POOL.with { |redis| redis.get(RateCache::TABLE_KEY) }
  end

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

  test "only one caller gets the lock at a time" do
    token = @cache.acquire_lock

    assert_not_nil token
    assert_nil @cache.acquire_lock
  end

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

  # Real wait, because the expiry lives in Redis and travel_to cannot move Redis's clock.
  test "the lock expires by itself" do
    old_token = @cache.acquire_lock(ttl: 0.1.seconds)
    sleep 0.15

    new_token = @cache.acquire_lock
    assert_not_nil new_token
    assert_not @cache.release_lock(old_token)
    assert_nil @cache.acquire_lock, "the old holder must not have released the new lock"
  end
end
