require "test_helper"

class RateApiClientTest < ActiveSupport::TestCase
  SUMMER = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }.freeze
  WINTER = { period: "Winter", hotel: "GitawayHotel", room: "BooleanTwin" }.freeze

  def body_with_rates(summer_rate, winter_rate)
    { rates: [SUMMER.merge(rate: summer_rate), WINTER.merge(rate: winter_rate)] }.to_json
  end

  test "rates sent as numbers or numeric strings both become integers" do
    [[56900, 35900], ["56900", "35900"]].each do |summer_rate, winter_rate|
      result = RateApiClient.parse_rates(body_with_rates(summer_rate, winter_rate), [SUMMER, WINTER])

      assert result.ok?
      assert_equal(
        { "Summer|FloatingPointResort|SingletonRoom" => 56900, "Winter|GitawayHotel|BooleanTwin" => 35900 },
        result.rates
      )
    end
  end

  # Seen in about 6% of real upstream calls: HTTP 200 but no rates.
  test "a 200 with an error message instead of rates is an error_body failure" do
    body = { message: "Failed to process rates due to an intermittent issue.", status: "error" }.to_json

    result = RateApiClient.parse_rates(body, [SUMMER])

    assert_equal :error_body, result.kind
    assert_nil result.rates
  end

  # One bad rate makes the whole response unusable, so nothing partial is cached.
  test "a null, decimal, negative or junk rate fails the whole response" do
    [nil, 56900.5, -1, "-1", "56900.0", "12a", "", true].each do |bad_rate|
      result = RateApiClient.parse_rates(body_with_rates(56900, bad_rate), [SUMMER, WINTER])

      assert_equal :invalid_rates, result.kind, "expected #{bad_rate.inspect} to be rejected"
      assert_nil result.rates
    end
  end

  test "a response missing a requested key fails" do
    body = { rates: [SUMMER.merge(rate: 56900)] }.to_json

    assert_equal :invalid_rates, RateApiClient.parse_rates(body, [SUMMER, WINTER]).kind
  end

  test "keys we did not ask for are dropped" do
    result = RateApiClient.parse_rates(body_with_rates(56900, 35900), [SUMMER])

    assert_equal({ "Summer|FloatingPointResort|SingletonRoom" => 56900 }, result.rates)
  end

  test "a body that is not JSON, or JSON of the wrong shape, fails without raising" do
    assert_equal :invalid_json, RateApiClient.parse_rates("<html>oops</html>", [SUMMER]).kind
    assert_equal :error_body, RateApiClient.parse_rates("[1, 2]", [SUMMER]).kind
    assert_equal :invalid_rates, RateApiClient.parse_rates({ rates: ["x"] }.to_json, [SUMMER]).kind
  end
end
