# Refreshes the whole rate table with one upstream call, and only one process
# at a time (Redis lock). No retry inside a refresh: every attempt costs quota,
# and the 3-5 minute window already gives later requests the next chance.
class RateRefresher
  # status: :refreshed (table is set), :failed, or :busy (someone else holds the lock)
  Outcome = Data.define(:status, :table)

  def initialize(cache: RateCache.new)
    @cache = cache
  end

  def call
    token = @cache.acquire_lock
    return Outcome.new(status: :busy, table: nil) if token.nil?

    begin
      fetch_and_store
    ensure
      @cache.release_lock(token)
    end
  end

  private

  def fetch_and_store
    # Age is measured from before the request, so a slow call eats into it.
    fetched_at = Time.current.to_f
    result = RateApiClient.fetch_rates(RateCatalog::ALL_ATTRIBUTES)
    log(result, fetched_at)

    if result.ok? && @cache.write(rates: result.rates, fetched_at:)
      @cache.record_success
      Outcome.new(status: :refreshed, table: RateCache::Table.new(rates: result.rates, fetched_at:))
    else
      # 429: quota is spent, counting failures would not help, wait it out.
      result.kind == :quota_exceeded ? @cache.start_quota_cooldown : @cache.record_failure
      Outcome.new(status: :failed, table: nil)
    end
  end

  def log(result, started_at)
    entry = {
      event: "rate_refresh",
      outcome: result.kind,
      http_status: result.http_status,
      latency_ms: ((Time.current.to_f - started_at) * 1000).round
    }.to_json

    case result.kind
    when :ok then Rails.logger.info(entry)
    when :bad_request then Rails.logger.error(entry) # our batch is wrong: a bug, not upstream flakiness
    else Rails.logger.warn(entry)
    end
  end
end
