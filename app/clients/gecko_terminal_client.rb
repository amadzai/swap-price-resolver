require "json"
require "net/http"

class GeckoTerminalClient
  BASE_URL = "https://api.geckoterminal.com/api/v2"
  TIMEOUT_SECONDS = 3

  class Error < StandardError; end

  class ParseError < Error; end

  class RateLimitedError < Error; end

  class UpstreamError < Error
    attr_reader :status

    def initialize(message, status:)
      super(message)
      @status = status
    end
  end

  def initialize(base_url: BASE_URL, open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS)
    @base_url = base_url
    @open_timeout = open_timeout
    @read_timeout = read_timeout
  end

  def fetch_pool_trades(network:, pool_address:)
    path = "/networks/#{network}/pools/#{pool_address}/trades"
    payload = request_json(path)
    trades = payload["data"]

    unless trades.is_a?(Array)
      raise ParseError, "Expected trades response data to be an array."
    end

    trades.map { |trade| normalize_trade(trade) }
  end

  def fetch_token_usd_price(network:, token_address:)
    normalized_token_address = token_address.to_s.downcase
    path = "/simple/networks/#{network}/token_price/#{normalized_token_address}"
    payload = request_json(path)
    token_prices = payload.dig("data", "attributes", "token_prices")

    unless token_prices.is_a?(Hash)
      raise ParseError, "Expected token_prices map in token price response."
    end

    usd_price = token_prices[normalized_token_address]

    if usd_price.nil?
      raise ParseError, "Token price missing for #{normalized_token_address}."
    end

    {
      token_address: normalized_token_address,
      usd_price: usd_price.to_s,
      observed_at: Time.now.utc.iso8601,
      source_url: "#{@base_url}#{path}"
    }
  end

  private

  def normalize_trade(trade)
    unless trade.is_a?(Hash)
      raise ParseError, "Expected each trade item to be a hash."
    end

    trade_id = trade["id"]
    attributes = trade["attributes"]
    unless trade_id.is_a?(String) && attributes.is_a?(Hash)
      raise ParseError, "Expected trade item to include id and attributes."
    end

    swap_log_index = parse_swap_log_index(trade_id)
    if swap_log_index.nil?
      raise ParseError, "Could not parse swap_log_index from trade id: #{trade_id}."
    end

    {
      id: trade_id,
      tx_hash: attributes["tx_hash"],
      swap_log_index: swap_log_index,
      block_timestamp: attributes["block_timestamp"],
      from_token_address: attributes["from_token_address"]&.downcase,
      to_token_address: attributes["to_token_address"]&.downcase,
      from_token_amount: attributes["from_token_amount"],
      to_token_amount: attributes["to_token_amount"]
    }
  end

  def parse_swap_log_index(trade_id)
    parts = trade_id.split("_")
    # Expects format of network_blockNumber_txHash_swapLogIndex_timestamp
    return nil unless parts.length == 5

    swap_log_index = parts[-2]
    Integer(swap_log_index, 10)
  rescue ArgumentError
    nil
  end

  def request_json(path)
    uri = URI("#{@base_url}#{path}")
    response = perform_get(uri)
    parse_response(response)
  end

  def perform_get(uri)
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/json"

    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: @open_timeout,
      read_timeout: @read_timeout
    ) do |http|
      http.request(request)
    end
  rescue Timeout::Error => e
    raise UpstreamError.new("Upstream request timed out: #{e.message}", status: 504)
  rescue SocketError, SystemCallError => e
    raise UpstreamError.new("Network error while calling GeckoTerminal: #{e.message}", status: 502)
  end

  def parse_response(response)
    status = response.code.to_i

    case response
    when Net::HTTPSuccess
      parse_json_body(response.body)
    when Net::HTTPTooManyRequests
      raise RateLimitedError.new(error_title_from_body(response.body) || "GeckoTerminal rate limit reached.")
    else
      raise UpstreamError.new(
        error_title_from_body(response.body) || "GeckoTerminal request failed with HTTP #{status}.",
        status: status
      )
    end
  end

  def parse_json_body(body)
    JSON.parse(body)
  rescue JSON::ParserError => e
    raise ParseError, "Invalid JSON response: #{e.message}"
  end

  def error_title_from_body(body)
    parsed = parse_json_body(body)
    errors = parsed["errors"]
    first_error = errors.is_a?(Array) ? errors.first : nil
    title = first_error.is_a?(Hash) ? first_error["title"] : nil

    return nil if title.nil? || title.strip.empty?

    title
  rescue ParseError
    nil
  end
end
