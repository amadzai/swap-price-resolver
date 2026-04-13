require "test_helper"

class SwapPriceHandlerTest < ActiveSupport::TestCase
  class FakeClient
    def initialize(trades:, price: nil, price_error: nil)
      @trades = trades
      @price = price
      @price_error = price_error
    end

    def fetch_pool_trades(network:, pool_address:)
      @last_trades_args = { network: network, pool_address: pool_address }
      @trades
    end

    def fetch_token_usd_price(network:, token_address:)
      @last_price_args = { network: network, token_address: token_address }
      raise @price_error if @price_error

      @price
    end
  end

  class FakeCache
    def initialize(seed = {})
      @store = seed
    end

    def read(key)
      @store[key]
    end

    def write(key, value, **)
      @store[key] = value
    end
  end

  test "resolves swap price when base token is from_token" do
    client = FakeClient.new(
      trades: [
        {
          tx_hash: "0xtxhash",
          swap_log_index: 10,
          block_timestamp: "2026-04-13T00:00:00Z",
          from_token_address: "0xbase",
          to_token_address: "0xquote",
          from_token_amount: "2",
          to_token_amount: "4000"
        }
      ],
      price: {
        token_address: "0xquote",
        usd_price: "1.00",
        observed_at: "2026-04-13T00:01:00Z",
        source_url: "https://example.test/price"
      }
    )
    cache = FakeCache.new

    result = Rails.stub(:cache, cache) do
      SwapPriceHandler.call(
        network: "eth",
        base_token_address: "0xbase",
        tx_hash: "0xtxhash",
        swap_log_index: 10,
        pool_address: "0xpool",
        client: client
      )
    end

    assert_equal "0xquote", result[:quote_token_address]
    assert_equal "2000.0", result[:swap_price_quote_in_base]
    assert_equal "1.0", result[:quote_token_usd_price]
    assert_equal "2000.0", result[:base_token_usd_price]
    assert_equal "live", result[:source]
  end

  test "resolves swap price when base token is to_token" do
    client = FakeClient.new(
      trades: [
        {
          tx_hash: "0xtxhash",
          swap_log_index: 11,
          block_timestamp: "2026-04-13T00:00:00Z",
          from_token_address: "0xquote",
          to_token_address: "0xbase",
          from_token_amount: "4000",
          to_token_amount: "2"
        }
      ],
      price: {
        token_address: "0xquote",
        usd_price: "1.00",
        observed_at: "2026-04-13T00:01:00Z",
        source_url: "https://example.test/price"
      }
    )
    cache = FakeCache.new

    result = Rails.stub(:cache, cache) do
      SwapPriceHandler.call(
        network: "eth",
        base_token_address: "0xbase",
        tx_hash: "0xtxhash",
        swap_log_index: 11,
        pool_address: "0xpool",
        client: client
      )
    end

    assert_equal "0xquote", result[:quote_token_address]
    assert_equal "2000.0", result[:swap_price_quote_in_base]
    assert_equal "2000.0", result[:base_token_usd_price]
  end

  test "raises swap not found when tx hash and swap index do not match" do
    client = FakeClient.new(trades: [], price: nil)
    cache = FakeCache.new

    assert_raises(SwapPriceHandler::SwapNotFoundError) do
      Rails.stub(:cache, cache) do
        SwapPriceHandler.call(
          network: "eth",
          base_token_address: "0xbase",
          tx_hash: "0xmissing",
          swap_log_index: 1,
          pool_address: "0xpool",
          client: client
        )
      end
    end
  end

  test "uses stale cached quote token price on 429" do
    stale_key = "gecko_terminal/token_price/stale/eth/0xquote"
    stale_price = {
      token_address: "0xquote",
      usd_price: "1.5",
      observed_at: "2026-04-13T00:01:00Z",
      source_url: "https://example.test/stale-price"
    }

    client = FakeClient.new(
      trades: [
        {
          tx_hash: "0xtxhash",
          swap_log_index: 12,
          block_timestamp: "2026-04-13T00:00:00Z",
          from_token_address: "0xbase",
          to_token_address: "0xquote",
          from_token_amount: "2",
          to_token_amount: "4000"
        }
      ],
      price_error: GeckoTerminalClient::RateLimitedError.new("rate limited")
    )
    cache = FakeCache.new(stale_key => stale_price)

    result = Rails.stub(:cache, cache) do
      SwapPriceHandler.call(
        network: "eth",
        base_token_address: "0xbase",
        tx_hash: "0xtxhash",
        swap_log_index: 12,
        pool_address: "0xpool",
        client: client
      )
    end

    assert_equal "1.5", result[:quote_token_usd_price]
    assert_equal "3000.0", result[:base_token_usd_price]
    assert_equal "https://example.test/stale-price", result[:quote_token_price_source]
  end

  test "raises invalid swap error when base token does not match trade sides" do
    client = FakeClient.new(
      trades: [
        {
          tx_hash: "0xtxhash",
          swap_log_index: 13,
          block_timestamp: "2026-04-13T00:00:00Z",
          from_token_address: "0xone",
          to_token_address: "0xtwo",
          from_token_amount: "2",
          to_token_amount: "4000"
        }
      ],
      price: {
        token_address: "0xquote",
        usd_price: "1.00",
        observed_at: "2026-04-13T00:01:00Z",
        source_url: "https://example.test/price"
      }
    )
    cache = FakeCache.new

    assert_raises(SwapPriceHandler::InvalidSwapError) do
      Rails.stub(:cache, cache) do
        SwapPriceHandler.call(
          network: "eth",
          base_token_address: "0xbase",
          tx_hash: "0xtxhash",
          swap_log_index: 13,
          pool_address: "0xpool",
          client: client
        )
      end
    end
  end

  test "re-raises rate limited error when stale cache is unavailable" do
    client = FakeClient.new(
      trades: [
        {
          tx_hash: "0xtxhash",
          swap_log_index: 14,
          block_timestamp: "2026-04-13T00:00:00Z",
          from_token_address: "0xbase",
          to_token_address: "0xquote",
          from_token_amount: "2",
          to_token_amount: "4000"
        }
      ],
      price_error: GeckoTerminalClient::RateLimitedError.new("rate limited")
    )
    cache = FakeCache.new

    assert_raises(GeckoTerminalClient::RateLimitedError) do
      Rails.stub(:cache, cache) do
        SwapPriceHandler.call(
          network: "eth",
          base_token_address: "0xbase",
          tx_hash: "0xtxhash",
          swap_log_index: 14,
          pool_address: "0xpool",
          client: client
        )
      end
    end
  end
end
