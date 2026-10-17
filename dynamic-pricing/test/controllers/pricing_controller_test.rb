require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
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

  test "returns 503 upstream_quota_exhausted with a 1 hour Retry-After when upstream says 429" do
    mock_result = RateApiClient::Result.new(kind: :quota_exceeded, rates: nil, http_status: 429)

    RateApiClient.stub(:fetch_rates, mock_result) do
      get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
    end

    assert_response :service_unavailable
    assert_equal "3600", @response.headers["Retry-After"]
    assert_equal "upstream_quota_exhausted", JSON.parse(@response.body)["code"]
  end

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

  test "a success response has no Retry-After header" do
    rates = { RateCache.key_for("Summer", "FloatingPointResort", "SingletonRoom") => 15000 }

    RateApiClient.stub(:fetch_rates, RateApiClient::Result.new(kind: :ok, rates:, http_status: 200)) do
      get api_v1_pricing_url, params: { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }
    end

    assert_response :success
    assert_nil @response.headers["Retry-After"]
  end

  test "should return error without any parameters" do
    get api_v1_pricing_url

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Missing required parameters"
    assert_equal "invalid_params", json_response["code"]
  end

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
end
