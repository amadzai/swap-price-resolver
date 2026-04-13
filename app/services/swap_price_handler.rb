require "bigdecimal"

class SwapPriceHandler
  class Error < StandardError; end

  class SwapNotFoundError < Error; end

  class InvalidSwapError < Error; end

  def self.call(...)
    new(...).call
  end

  def initialize(network:, base_token_address:, tx_hash:, swap_log_index:, pool_address:,
                 client: GeckoTerminalClient.new)
    @network = network
    @base_token_address = base_token_address.to_s.downcase
    @tx_hash = tx_hash.to_s.downcase
    @swap_log_index = Integer(swap_log_index)
    @pool_address = pool_address
    @client = client
  end

  def call
    trade = find_trade!
    quote_token_address, base_amount, quote_amount = extract_swap_sides!(trade)

    swap_price_quote_in_base = quote_amount / base_amount
    quote_token_price = fetch_quote_token_price(quote_token_address)
    quote_token_usd_price = BigDecimal(quote_token_price[:usd_price])
    base_token_usd_price = swap_price_quote_in_base * quote_token_usd_price

    {
      network: @network,
      pool_address: @pool_address,
      tx_hash: @tx_hash,
      swap_log_index: @swap_log_index,
      block_timestamp: trade.fetch(:block_timestamp),
      base_token_address: @base_token_address,
      quote_token_address: quote_token_address,
      swap_price_quote_in_base: swap_price_quote_in_base.to_s("F"),
      base_token_usd_price: base_token_usd_price.to_s("F"),
      quote_token_usd_price: quote_token_usd_price.to_s("F"),
      quote_token_price_source: quote_token_price.fetch(:source_url),
      quote_token_price_observed_at: quote_token_price.fetch(:observed_at),
      source: "live"
    }
  end

  private

  def find_trade!
    trades = @client.fetch_pool_trades(network: @network, pool_address: @pool_address)

    trade = trades.find do |entry|
      entry.fetch(:tx_hash).to_s.downcase == @tx_hash &&
        entry.fetch(:swap_log_index) == @swap_log_index
    end

    return trade if trade

    raise SwapNotFoundError, "Swap not found for tx_hash=#{@tx_hash} swap_log_index=#{@swap_log_index}."
  end

  def extract_swap_sides!(trade)
    from_token_address = trade.fetch(:from_token_address).to_s.downcase
    to_token_address = trade.fetch(:to_token_address).to_s.downcase
    from_amount = BigDecimal(trade.fetch(:from_token_amount).to_s)
    to_amount = BigDecimal(trade.fetch(:to_token_amount).to_s)

    raise InvalidSwapError, "Swap amount cannot be zero." if from_amount.zero? || to_amount.zero?

    if from_token_address == @base_token_address
      [ to_token_address, from_amount, to_amount ]
    elsif to_token_address == @base_token_address
      [ from_token_address, to_amount, from_amount ]
    else
      raise InvalidSwapError, "Base token #{@base_token_address} does not match swap token sides."
    end
  end

  def fetch_quote_token_price(quote_token_address)
    Rails.cache.fetch(cache_key_for(quote_token_address), expires_in: 60.seconds) do
      @client.fetch_token_usd_price(network: @network, token_address: quote_token_address)
    end
  end

  def cache_key_for(quote_token_address)
    "gecko_terminal/token_price/#{@network}/#{quote_token_address}"
  end
end
