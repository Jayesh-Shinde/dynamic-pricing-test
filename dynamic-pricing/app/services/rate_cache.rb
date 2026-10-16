# Stores the full table of rates (all combinations) in Redis as one JSON value,
# and hands it back only while it is still servable (no older than max_age).
#
# Two independent guards against serving old data:
#   1. Redis expiry (PX) set on write, so old data disappears by itself.
#   2. An age check on read against our own clock.
class RateCache
  TABLE_KEY = "rates:table"

  Table = Data.define(:rates, :fetched_at) do
    def age
      Time.current.to_f - fetched_at
    end

    def rate_for(period, hotel, room)
      rates[RateCache.key_for(period, hotel, room)]
    end
  end

  def self.key_for(period, hotel, room)
    [period, hotel, room].join("|")
  end

  def initialize(pool: REDIS_POOL, max_age: 5.minutes)
    @pool = pool
    @max_age = max_age.to_f
  end

  # Returns a Table, or nil when there is nothing servable
  # (missing, corrupt, or older than max_age).
  def read
    raw = @pool.with { |redis| redis.get(TABLE_KEY) }
    return nil if raw.nil?

    data = JSON.parse(raw)
    unless data.is_a?(Hash) && data["rates"].is_a?(Hash) && data["fetched_at"].is_a?(Numeric)
      Rails.logger.warn({ event: "rate_cache.corrupt_entry" }.to_json)
      return nil
    end

    table = Table.new(rates: data["rates"], fetched_at: data["fetched_at"])
    table.age <= @max_age ? table : nil
  rescue JSON::ParserError
    Rails.logger.warn({ event: "rate_cache.corrupt_entry" }.to_json)
    nil
  end

  # fetched_at: epoch seconds taken just before the upstream request was sent.
  # Returns false (and stores nothing) if the data is already too old to serve.
  def write(rates:, fetched_at:)
    remaining_ms = ((@max_age - (Time.current.to_f - fetched_at)) * 1000).floor
    return false if remaining_ms <= 0

    payload = { fetched_at: fetched_at, rates: rates }.to_json
    @pool.with { |redis| redis.set(TABLE_KEY, payload, px: remaining_ms) }
    true
  end
end
