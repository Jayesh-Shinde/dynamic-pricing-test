module Api::V1
  # Serves one rate from the cached table, refreshing the table when needed.
  #   under 3 min    -> serve the cache
  #   3 to 5 min     -> serve the cache; one request refreshes it first
  #   over 5 / empty -> one request refreshes, the others wait for it; error if that fails
  # Never serves a rate older than 5 minutes.
  #
  # Output (BaseService pattern): run's return value is not used. Afterwards,
  # either result is the rate (Integer), or failure is set and valid? is false.
  class PricingService < BaseService
    REFRESH_AFTER = 3.minutes
    POLL_INTERVAL = 0.2 # seconds; a good refresh takes ~10 ms
    POLL_DEADLINE = 4.0 # seconds; the winner's 3 s timeout plus margin
    DEFAULT_RETRY_AFTER = 5 # seconds, when there is no cooldown to report

    # Why no rate could be served, for the controller to turn into a response.
    # code: :rates_unavailable, :upstream_quota_exhausted or :cache_unavailable
    Failure = Data.define(:code, :retry_after)

    attr_reader :failure

    def initialize(period:, hotel:, room:, cache: RateCache.new, poll_deadline: POLL_DEADLINE)
      @period = period
      @hotel = hotel
      @room = room
      @cache = cache
      @refresher = RateRefresher.new(cache:)
      @poll_deadline = poll_deadline
    end

    def run
      table = @cache.read

      table =
        if table.nil? then fetch_missing
        elsif table.age > REFRESH_AFTER then refresh_early(table)
        else table
        end

      serve(table)
    rescue Redis::BaseError, ConnectionPool::TimeoutError
      # Fail closed: without Redis we have no lock and no cooldown, so going
      # straight to upstream could burn the daily quota.
      fail_with(:cache_unavailable, DEFAULT_RETRY_AFTER)
    end

    private

    # The cache is still servable: refresh if nobody else is, but never make
    # the user pay for a failure. Losers and cooldowns just serve the cache.
    # Returns: RateCache::Table (the new one, or the one passed in)
    def refresh_early(table)
      return table if @cache.cooldown_remaining

      outcome = @refresher.call
      outcome.status == :refreshed ? outcome.table : table
    end

    # Nothing servable: we need fresh data or an error.
    # Returns: RateCache::Table, or nil (serve turns nil into the failure)
    def fetch_missing
      return nil if @cache.cooldown_remaining

      outcome = @refresher.call
      case outcome.status
      when :refreshed then outcome.table
      when :busy then wait_for_winner
      end
    end

    # Someone else is refreshing. Watch the cache, never call upstream and never
    # try the lock again (that would make us a second refresher).
    # Returns: RateCache::Table, or nil if the deadline passed
    def wait_for_winner
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @poll_deadline
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep POLL_INTERVAL
        table = @cache.read
        return table if table
      end
      nil
    end

    # Age is checked again here, not only when picking a branch: a 4m58s table
    # plus a 3 s failed refresh would otherwise be served at 5m01s.
    # Sets result or failure. table: RateCache::Table or nil
    def serve(table)
      rate = table.rate_for(@period, @hotel, @room) if @cache.servable?(table)

      if rate.nil?
        code = @cache.cooldown_reason == "quota" ? :upstream_quota_exhausted : :rates_unavailable
        return fail_with(code, @cache.cooldown_remaining || DEFAULT_RETRY_AFTER)
      end

      @result = rate
    end

    # Sets failure. code: one of the Failure codes; retry_after: whole seconds
    def fail_with(code, retry_after)
      @failure = Failure.new(code:, retry_after:)
      # Until the controller renders failures itself (chunk 11).
      errors << "Fresh rates are temporarily unavailable. Please retry shortly."
    end
  end
end
