class SwapPricesController < ApplicationController
  REQUIRED_PARAMS = %w[network base_token_address tx_hash swap_log_index pool_address].freeze

  def show
    missing = missing_params
    if missing.any?
      render json: { error: "Missing required params: #{missing.join(', ')}" }, status: :unprocessable_entity
      return
    end

    result = SwapPriceHandler.call(
      network: params[:network],
      base_token_address: params[:base_token_address],
      tx_hash: params[:tx_hash],
      swap_log_index: params[:swap_log_index],
      pool_address: params[:pool_address]
    )

    render json: { data: result }, status: :ok
  rescue SwapPriceHandler::SwapNotFoundError => e
    render json: { error: e.message }, status: :not_found
  rescue SwapPriceHandler::InvalidSwapError, ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue GeckoTerminalClient::RateLimitedError => e
    render json: { error: e.message }, status: :service_unavailable
  rescue GeckoTerminalClient::UpstreamError => e
    render json: { error: e.message }, status: :bad_gateway
  rescue GeckoTerminalClient::ParseError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def missing_params
    REQUIRED_PARAMS.filter { |key| params[key].blank? }
  end
end
