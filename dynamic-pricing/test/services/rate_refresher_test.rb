require "test_helper"

class RateRefresherTest < ActiveSupport::TestCase
  KEY = RateCache.key_for("Summer", "FloatingPointResort", "SingletonRoom")

  setup do
    @cache = RateCache.new
    @refresher = RateRefresher.new(cache: @cache)
  end

  def ok_result
    RateApiClient::Result.new(kind: :ok, rates: { KEY => 56900 }, http_status: 200)
  end

  def failed_result(kind, http_status = nil)
    RateApiClient::Result.new(kind:, rates: nil, http_status:)
  end

  def failure_count
    REDIS_POOL.with { |redis| redis.get(RateCache::FAILURES_KEY) }
  end

  # Happy path: table cached and returned. Failure cleared. Lock freed.
  test "success caches the table, returns it, clears the failure count and releases the lock" do
    @cache.record_failure

    outcome = RateApiClient.stub(:fetch_rates, ok_result) { @refresher.call }

    assert_equal :refreshed, outcome.status
    assert_equal 56900, outcome.table.rates[KEY]
    assert_equal 56900, @cache.read.rates[KEY]
    assert_nil failure_count
    assert @cache.acquire_lock, "lock should have been released"
  end

  # One batch with all 36 keys = one quota unit per refresh.
  test "requests all 36 combinations in one call" do
    sent = nil
    fake = ->(attributes) { sent = attributes; ok_result }

    RateApiClient.stub(:fetch_rates, fake) { @refresher.call }

    assert_equal RateCatalog::ALL_ATTRIBUTES, sent
  end

  # Lock already held -> :busy and no upstream call. quota is never spent.
  test "returns busy without calling upstream when another process holds the lock" do
    @cache.acquire_lock
    must_not_call = ->(_) { flunk "upstream must not be called" }

    outcome = RateApiClient.stub(:fetch_rates, must_not_call) { @refresher.call }

    assert_equal :busy, outcome.status
  end

  # Timeout: nothing cached, 5s cooldown starts, lock still released.
  test "a failed call caches nothing, starts a failure cooldown and releases the lock" do
    outcome = RateApiClient.stub(:fetch_rates, failed_result(:timeout)) { @refresher.call }

    assert_equal :failed, outcome.status
    assert_nil @cache.read
    assert_equal "1", failure_count
    assert_equal 5, @cache.cooldown_remaining
    assert @cache.acquire_lock, "lock should have been released"
  end

  # 429 sets the 1hr quota cooldown without counting a failure.
  test "upstream 429 starts the long quota cooldown without counting a failure" do
    outcome = RateApiClient.stub(:fetch_rates, failed_result(:quota_exceeded, 429)) { @refresher.call }

    assert_equal :failed, outcome.status
    assert_nil failure_count
    assert_equal 1.hour.to_i, @cache.cooldown_remaining
  end

  # Release is in ensure so a crash cannot leave the lock stuck until its TTL.
  test "the lock is released even if the call raises unexpectedly" do
    boom = ->(_) { raise "unexpected" }

    assert_raises(RuntimeError) do
      RateApiClient.stub(:fetch_rates, boom) { @refresher.call }
    end
    assert @cache.acquire_lock, "lock should have been released"
  end
end
