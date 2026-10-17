class RateApiClient
  include HTTParty
  base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
  headers "Content-Type" => "application/json"
  headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')

  # Good calls take under 0.05 s. The slow ones take ~120 s and are charged
  # anyway, so give up fast instead of holding a Puma thread for a minute.
  TIMEOUT_SECONDS = ENV.fetch("RATE_API_TIMEOUT_SECONDS", 3).to_f
  open_timeout TIMEOUT_SECONDS
  read_timeout TIMEOUT_SECONDS

  def self.get_rate(period:, hotel:, room:)
    params = {
      attributes: [
        {
          period: period,
          hotel: hotel,
          room: room
        }
      ]
    }.to_json
    self.post("/pricing", body: params)
  end

  # kind is :ok, or the reason the call failed. rates is only set when :ok.
  Result = Data.define(:kind, :rates, :http_status) do
    def ok?
      kind == :ok
    end
  end

  # One call for any number of keys: it costs one quota unit either way.
  # Never raises for network or upstream problems; always returns a Result.
  def self.fetch_rates(attributes)
    response = post("/pricing", body: { attributes: }.to_json)

    case response.code
    when 200 then parse_rates(response.body, attributes)
    when 429 then failure(:quota_exceeded, 429)
    when 400 then failure(:bad_request, 400) # our request was wrong, not the user's
    else failure(:http_error, response.code)
    end
  rescue Timeout::Error # Net::OpenTimeout and Net::ReadTimeout are both Timeout::Errors
    failure(:timeout)
  rescue SocketError, SystemCallError, IOError, HTTParty::Error # DNS, refused, reset, ...
    failure(:connection_error)
  end

  # Turns a 200 body into { "Summer|FloatingPointResort|SingletonRoom" => 56900, ... }
  # for exactly the requested attributes.
  # All or nothing: if anything is wrong, no rates are returned, so a bad
  # response can never end up in the cache.
  def self.parse_rates(body, attributes)
    data = JSON.parse(body)
    items = data["rates"] if data.is_a?(Hash)
    # e.g. {"message": "Failed to process rates ...", "status": "error"}
    return failure(:error_body, 200) unless items.is_a?(Array)

    rates = {}
    items.each do |item|
      return failure(:invalid_rates, 200) unless item.is_a?(Hash)

      rate = normalize_rate(item["rate"])
      return failure(:invalid_rates, 200) if rate.nil?

      rates[RateCache.key_for(item["period"], item["hotel"], item["room"])] = rate
    end

    wanted = attributes.map { |a| RateCache.key_for(a[:period], a[:hotel], a[:room]) }
    return failure(:invalid_rates, 200) unless (wanted - rates.keys).empty?

    Result.new(kind: :ok, rates: rates.slice(*wanted), http_status: 200)
  rescue JSON::ParserError
    failure(:invalid_json, 200)
  end

  # Upstream sends the rate as a number or as a numeric string.
  # Only whole, non-negative values are accepted; we always return an Integer.
  # Anything else (null, decimal, negative, junk) returns nil.
  def self.normalize_rate(value)
    case value
    when Integer then value if value >= 0
    when /\A\d+\z/ then value.to_i
    end
  end

  def self.failure(kind, http_status = nil)
    Result.new(kind:, rates: nil, http_status:)
  end
  private_class_method :normalize_rate, :failure
end
