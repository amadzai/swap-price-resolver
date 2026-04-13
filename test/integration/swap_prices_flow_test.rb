require "test_helper"

class SwapPricesTest < ActionDispatch::IntegrationTest
  def valid_params
    {
      network: "eth",
      base_token_address: "0xbase",
      tx_hash: "0xtxhash",
      swap_log_index: "10",
      pool_address: "0xpool"
    }
  end

  test "returns resolved swap price data" do
    resolved_data = {
      network: "eth",
      pool_address: "0xpool",
      tx_hash: "0xtxhash",
      swap_log_index: 10,
      block_timestamp: "2026-04-13T00:00:00Z",
      base_token_address: "0xbase",
      quote_token_address: "0xquote",
      swap_price_quote_in_base: "2000.0",
      base_token_usd_price: "2000.0",
      quote_token_usd_price: "1.0",
      quote_token_price_source: "https://example.test/price",
      quote_token_price_observed_at: "2026-04-13T00:01:00Z",
      source: "live"
    }

    SwapPriceHandler.stub(:call, resolved_data) do
      get "/swap-price", params: valid_params
    end

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal resolved_data.stringify_keys, body["data"]
  end

  test "returns 422 when required params are missing" do
    get "/swap-price", params: { network: "eth" }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_includes body["error"], "Missing required params"
  end

  test "returns 404 when swap is not found" do
    SwapPriceHandler.stub(:call, ->(*) { raise SwapPriceHandler::SwapNotFoundError, "not found" }) do
      get "/swap-price", params: valid_params
    end

    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "not found", body["error"]
  end

  test "returns 503 on geckoterminal rate limit error" do
    SwapPriceHandler.stub(:call, ->(*) { raise GeckoTerminalClient::RateLimitedError, "rate limited" }) do
      get "/swap-price", params: valid_params
    end

    assert_response :service_unavailable
    body = JSON.parse(response.body)
    assert_equal "rate limited", body["error"]
  end

  test "returns 422 on argument error from handler" do
    SwapPriceHandler.stub(:call, ->(*) { raise ArgumentError, "invalid input" }) do
      get "/swap-price", params: valid_params
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "invalid input", body["error"]
  end

  test "returns 502 on upstream geckoterminal error" do
    error = GeckoTerminalClient::UpstreamError.new("upstream failed", status: 502)
    SwapPriceHandler.stub(:call, ->(*) { raise error }) do
      get "/swap-price", params: valid_params
    end

    assert_response :bad_gateway
    body = JSON.parse(response.body)
    assert_equal "upstream failed", body["error"]
  end

  test "returns 502 on parse error from geckoterminal response" do
    SwapPriceHandler.stub(:call, ->(*) { raise GeckoTerminalClient::ParseError, "invalid json" }) do
      get "/swap-price", params: valid_params
    end

    assert_response :bad_gateway
    body = JSON.parse(response.body)
    assert_equal "invalid json", body["error"]
  end
end
