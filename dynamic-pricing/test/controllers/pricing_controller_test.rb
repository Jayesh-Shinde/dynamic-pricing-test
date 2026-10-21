require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  # Scaffold test, updated: a success returns the rate as an integer.
  test "should get pricing with all parameters" do
    rates = { RateCache.key_for("Summer", "FloatingPointResort", "SingletonRoom") => 15000 }
    mock_result = RateApiClient::Result.new(kind: :ok, rates:, http_status: 200)

    RateApiClient.stub(:fetch_rates, mock_result) do
      get api_v1_pricing_url, params: {
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      }

      assert_response :success
      assert_equal "application/json", @response.media_type

      json_response = JSON.parse(@response.body)
      assert_equal 15000, json_response["rate"] # always an integer, even if upstream sent "15000"
    end
  end

  # Scaffold test, updated: upstream 500 -> 503 rates_unavailable + Retry-After.
  test "should return error when rate API fails" do
    mock_result = RateApiClient::Result.new(kind: :http_error, rates: nil, http_status: 500)

    RateApiClient.stub(:fetch_rates, mock_result) do
      get api_v1_pricing_url, params: {
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      }

      # Changed from the scaffold's 400: an upstream failure is not the client's fault.
      assert_response :service_unavailable
      assert_equal "application/json", @response.media_type
      assert_equal "5", @response.headers["Retry-After"] # first failure: 5 s cooldown

      json_response = JSON.parse(@response.body)
      assert_equal "rates_unavailable", json_response["code"]
      assert_includes json_response["error"], "temporarily unavailable"
    end
  end

  # Full HTTP path for 429: 503 (our token's quota, not the caller's), Retry-After 3600.
  test "returns 503 upstream_quota_exhausted with a 1 hour Retry-After when upstream says 429" do
    mock_result = RateApiClient::Result.new(kind: :quota_exceeded, rates: nil, http_status: 429)

    RateApiClient.stub(:fetch_rates, mock_result) do
      get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
    end

    assert_response :service_unavailable
    assert_equal "3600", @response.headers["Retry-After"]
    assert_equal "upstream_quota_exhausted", JSON.parse(@response.body)["code"]
  end

  # Every Redis call raises: 503 cache_unavailable, and the upstream stub is never hit.
  test "returns 503 cache_unavailable when Redis is down, without calling upstream" do
    redis_down = ->(*) { raise Redis::CannotConnectError, "connection refused" }
    must_not_call = ->(_) { raise Minitest::Assertion, "upstream must not be called" }

    REDIS_POOL.stub(:with, redis_down) do
      RateApiClient.stub(:fetch_rates, must_not_call) do
        get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
      end
    end

    assert_response :service_unavailable
    assert_equal "5", @response.headers["Retry-After"]
    assert_equal "cache_unavailable", JSON.parse(@response.body)["code"]
  end

  # Retry-After is only sent with errors.
  test "a success response has no Retry-After header" do
    rates = { RateCache.key_for("Summer", "FloatingPointResort", "SingletonRoom") => 15000 }

    RateApiClient.stub(:fetch_rates, RateApiClient::Result.new(kind: :ok, rates:, http_status: 200)) do
      get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
    end

    assert_response :success
    assert_nil @response.headers["Retry-After"]
  end

  # Scaffold test: no params -> 400 invalid_params.
  test "should return error without any parameters" do
    get api_v1_pricing_url

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Missing required parameters"
    assert_equal "invalid_params", json_response["code"]
  end

  # Scaffold test: empty strings count as missing.
  test "should handle empty parameters" do
    get api_v1_pricing_url, params: {
      period: "",
      hotel: "",
      room: ""
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Missing required parameters"
    assert_equal "invalid_params", json_response["code"]
  end

  # Scaffold test: a value outside the catalog -> 400 naming the field.
  test "should reject invalid period" do
    get api_v1_pricing_url, params: {
      period: "summer-2024",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid period"
    assert_equal "invalid_params", json_response["code"]
  end

  # Scaffold test: a value outside the catalog -> 400 naming the field.
  test "should reject invalid hotel" do
    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "InvalidHotel",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid hotel"
    assert_equal "invalid_params", json_response["code"]
  end

  # Scaffold test: a value outside the catalog -> 400 naming the field.
  test "should reject invalid room" do
    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "InvalidRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid room"
    assert_equal "invalid_params", json_response["code"]
  end

  VALID_PARAMS = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }.freeze

  # One pricing_request JSON line: status 200, no code, and the age of the rate served.
  test "logs one pricing_request line for a served rate" do
    rates = { RateCache.key_for("Summer", "FloatingPointResort", "SingletonRoom") => 15000 }
    ok = RateApiClient::Result.new(kind: :ok, rates:, http_status: 200)

    logs = capture_request_logs do
      RateApiClient.stub(:fetch_rates, ok) { get api_v1_pricing_url, params: VALID_PARAMS }
    end

    assert_equal 1, logs.size
    assert_equal 200, logs[0]["status"]
    assert_nil logs[0]["code"]
    assert_kind_of Integer, logs[0]["rate_age_ms"]
    assert_kind_of Integer, logs[0]["latency_ms"]
  end

  # A 503 log line carries the error code and no rate age.
  test "logs the error code for a 503" do
    failed = RateApiClient::Result.new(kind: :http_error, rates: nil, http_status: 500)

    logs = capture_request_logs do
      RateApiClient.stub(:fetch_rates, failed) { get api_v1_pricing_url, params: VALID_PARAMS }
    end

    assert_equal 1, logs.size
    assert_equal 503, logs[0]["status"]
    assert_equal "rates_unavailable", logs[0]["code"]
    assert_nil logs[0]["rate_age_ms"]
  end

  # around_action wraps validate_params, so 400s are logged too.
  test "logs invalid params too, although validate_params stops the request" do
    logs = capture_request_logs do
      get api_v1_pricing_url, params: VALID_PARAMS.merge(room: "InvalidRoom")
    end

    assert_equal 1, logs.size
    assert_equal 400, logs[0]["status"]
    assert_equal "invalid_params", logs[0]["code"]
  end

  private

  # Returns the parsed "pricing_request" log entries written during the block.
  def capture_request_logs
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string.lines
      .filter_map { |line| JSON.parse(line) rescue nil }
      .select { |entry| entry["event"] == "pricing_request" }
  ensure
    Rails.logger = original
  end
end
