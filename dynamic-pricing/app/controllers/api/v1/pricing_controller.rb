class Api::V1::PricingController < ApplicationController
  before_action :validate_params

  def index
    period = params[:period]
    hotel  = params[:hotel]
    room   = params[:room]

    service = Api::V1::PricingService.new(period:, hotel:, room:)
    service.run
    if service.valid?
      render json: { rate: service.result }
    else
      render json: { error: service.errors.join(', ') }, status: :bad_request
    end
  end

  private

  def validate_params
    # Validate required parameters
    unless params[:period].present? && params[:hotel].present? && params[:room].present?
      return render json: { error: "Missing required parameters: period, hotel, room" }, status: :bad_request
    end

    # Validate parameter values
    unless RateCatalog::PERIODS.include?(params[:period])
      return render json: { error: "Invalid period. Must be one of: #{RateCatalog::PERIODS.join(', ')}" }, status: :bad_request
    end

    unless RateCatalog::HOTELS.include?(params[:hotel])
      return render json: { error: "Invalid hotel. Must be one of: #{RateCatalog::HOTELS.join(', ')}" }, status: :bad_request
    end

    unless RateCatalog::ROOMS.include?(params[:room])
      return render json: { error: "Invalid room. Must be one of: #{RateCatalog::ROOMS.join(', ')}" }, status: :bad_request
    end
  end
end
