class Api::V1::PricingController < ApplicationController
  # Declared first so it wraps validate_params too: 400s get a log line as well.
  around_action :log_request
  before_action :validate_params

  # All are 503: the request was fine, we just cannot serve a fresh rate right now.
  # (Not 429 for quota: the user did not exceed anything, our upstream token did.)
  FAILURE_MESSAGES = {
    rates_unavailable: "Fresh rates are temporarily unavailable. Please retry shortly.",
    upstream_quota_exhausted: "The rate provider's daily limit has been reached. Please retry later.",
    cache_unavailable: "The rate service is temporarily unavailable. Please retry shortly."
  }.freeze

  def index
    period = params[:period]
    hotel  = params[:hotel]
    room   = params[:room]

    @service = Api::V1::PricingService.new(period:, hotel:, room:)
    @service.run
    if @service.valid?
      render json: { rate: @service.result }
    else
      render_failure(@service.failure)
    end
  end

  private

  # One JSON line per request: what we answered, how old the rate was, how long it took.
  def log_request
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Rails.logger.info({
      event: "pricing_request",
      status: response.status,
      code: @error_code,
      rate_age_ms: @service&.rate_age_ms,
      latency_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    }.to_json)
  end

  def render_failure(failure)
    @error_code = failure.code
    response.headers["Retry-After"] = failure.retry_after.to_s
    render json: { error: FAILURE_MESSAGES.fetch(failure.code), code: failure.code },
           status: :service_unavailable
  end

  def validate_params
    # Validate required parameters
    unless params[:period].present? && params[:hotel].present? && params[:room].present?
      return render_invalid_params("Missing required parameters: period, hotel, room")
    end

    # Validate parameter values
    unless RateCatalog::PERIODS.include?(params[:period])
      return render_invalid_params("Invalid period. Must be one of: #{RateCatalog::PERIODS.join(', ')}")
    end

    unless RateCatalog::HOTELS.include?(params[:hotel])
      return render_invalid_params("Invalid hotel. Must be one of: #{RateCatalog::HOTELS.join(', ')}")
    end

    unless RateCatalog::ROOMS.include?(params[:room])
      return render_invalid_params("Invalid room. Must be one of: #{RateCatalog::ROOMS.join(', ')}")
    end
  end

  # Same shape as render_failure, so clients can always switch on "code".
  def render_invalid_params(message)
    @error_code = :invalid_params
    render json: { error: message, code: :invalid_params }, status: :bad_request
  end
end
