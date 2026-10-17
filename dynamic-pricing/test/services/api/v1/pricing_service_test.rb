require "test_helper"

class Api::V1::PricingServiceTest < ActiveSupport::TestCase
  KEY = RateCache.key_for("Summer", "FloatingPointResort", "SingletonRoom")

  setup do
    @cache = RateCache.new
  end

  def service(**options)
    Api::V1::PricingService.new(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom",
                                cache: @cache, **options)
  end

  def cache_rate(rate, age:)
    @cache.write(rates: { KEY => rate }, fetched_at: Time.current.to_f - age)
  end

  def upstream_ok(rate)
    RateApiClient::Result.new(kind: :ok, rates: { KEY => rate }, http_status: 200)
  end

  def upstream_failed(kind = :timeout)
    RateApiClient::Result.new(kind:, rates: nil, http_status: nil)
  end

  MUST_NOT_CALL = ->(_) { raise Minitest::Assertion, "upstream must not be called" }

  def run_with_upstream(response, svc = service)
    RateApiClient.stub(:fetch_rates, response) { svc.run }
    svc
  end

  # --- cache under 3 minutes ---

  test "a fresh cache is served without calling upstream" do
    cache_rate(100, age: 2.minutes)

    svc = run_with_upstream(MUST_NOT_CALL)

    assert_equal 100, svc.result
    assert svc.valid?
  end

  # --- cache between 3 and 5 minutes ---

  test "an aging cache is refreshed and the new rate served" do
    cache_rate(100, age: 4.minutes)

    assert_equal 200, run_with_upstream(upstream_ok(200)).result
  end

  test "an aging cache is still served when its refresh fails" do
    cache_rate(100, age: 4.minutes)

    assert_equal 100, run_with_upstream(upstream_failed).result
  end

  test "an aging cache is served without calling upstream during a cooldown" do
    cache_rate(100, age: 4.minutes)
    @cache.record_failure

    assert_equal 100, run_with_upstream(MUST_NOT_CALL).result
  end

  test "an aging cache is served at once when another process is refreshing" do
    cache_rate(100, age: 4.minutes)
    @cache.acquire_lock

    assert_equal 100, run_with_upstream(MUST_NOT_CALL).result
  end

  # --- cache empty or over 5 minutes ---

  test "an empty cache is filled and the rate served" do
    assert_equal 200, run_with_upstream(upstream_ok(200)).result
  end

  test "an empty cache with a failed refresh returns rates_unavailable" do
    svc = run_with_upstream(upstream_failed)

    assert_nil svc.result
    assert_not svc.valid?
    assert_equal :rates_unavailable, svc.failure.code
    assert_equal 5, svc.failure.retry_after # first failure: 5 s cooldown
  end

  test "an empty cache with an upstream 429 returns upstream_quota_exhausted with a 1 hour retry" do
    svc = run_with_upstream(upstream_failed(:quota_exceeded))

    assert_equal :upstream_quota_exhausted, svc.failure.code
    assert_equal 1.hour.to_i, svc.failure.retry_after
  end

  test "an empty cache during a quota cooldown returns upstream_quota_exhausted without calling upstream" do
    @cache.start_quota_cooldown

    svc = run_with_upstream(MUST_NOT_CALL)

    assert_equal :upstream_quota_exhausted, svc.failure.code
    assert_equal 1.hour.to_i, svc.failure.retry_after
  end

  test "a waiting request serves the winner's data and never calls upstream" do
    @cache.acquire_lock # another process is the winner
    winner = Thread.new do
      sleep 0.3
      cache_rate(300, age: 0)
    end

    svc = run_with_upstream(MUST_NOT_CALL)
    winner.join

    assert_equal 300, svc.result
  end

  test "a waiting request gives up after the deadline and never calls upstream" do
    @cache.acquire_lock

    svc = run_with_upstream(MUST_NOT_CALL, service(poll_deadline: 0.5))

    assert_equal :rates_unavailable, svc.failure.code
    assert_equal 5, svc.failure.retry_after # default: there is no cooldown to report
  end

  # --- concurrency important ---

  test "many requests at an empty cache make exactly one upstream call" do
    threads = 10
    calls = Queue.new # thread-safe; counts upstream calls
    slow_upstream = lambda do |_attributes|
      calls << 1
      sleep 0.3 # long enough that every other thread arrives while the winner is still fetching
      upstream_ok(500)
    end

    gate = Queue.new # each thread blocks on pop until we open the gate, so they start together
    results = Queue.new

    RateApiClient.stub(:fetch_rates, slow_upstream) do
      workers = Array.new(threads) do
        Thread.new do
          gate.pop
          svc = service
          svc.run
          results << svc.result
        end
      end
      threads.times { gate << :go }
      workers.each(&:join)
    end

    assert_equal 1, calls.size
    assert_equal [500] * threads, Array.new(threads) { results.pop }
  end

  # --- serve-time age check ---

  test "a 4m58s cache is not served at 5m01s after a slow failed refresh" do
    freeze_time
    cache_rate(100, age: 4.minutes + 58.seconds)
    slow_failure = ->(_) { travel 3.seconds; upstream_failed }

    svc = run_with_upstream(slow_failure)

    assert_nil svc.result
    assert_equal :rates_unavailable, svc.failure.code
  end

  # --- Redis down ---

  test "Redis down returns cache_unavailable without calling upstream" do
    redis_down = -> { raise Redis::CannotConnectError, "connection refused" }

    svc = @cache.stub(:read, redis_down) { run_with_upstream(MUST_NOT_CALL) }

    assert_equal :cache_unavailable, svc.failure.code
  end
end
