require "test_helper"
require "net/http"

class GeckoTerminalClientTest < ActiveSupport::TestCase
  test "fetch_pool_trades normalizes trade payload" do
    payload = {
      "data" => [
        {
          "id" => "eth_1_0xtxhash_10_123456",
          "attributes" => {
            "tx_hash" => "0xTxHash",
            "block_timestamp" => "2026-04-13T00:00:00Z",
            "from_token_address" => "0xBASE",
            "to_token_address" => "0xQUOTE",
            "from_token_amount" => "2",
            "to_token_amount" => "4000"
          }
        }
      ]
    }

    client = GeckoTerminalClient.new
    trades = client.stub(:request_json, payload) do
      client.fetch_pool_trades(network: "eth", pool_address: "0xpool")
    end

    assert_equal 1, trades.size
    assert_equal "eth_1_0xtxhash_10_123456", trades.first[:id]
    assert_equal 10, trades.first[:swap_log_index]
    assert_equal "0xbase", trades.first[:from_token_address]
    assert_equal "0xquote", trades.first[:to_token_address]
  end

  test "fetch_pool_trades raises when trades data is not an array" do
    client = GeckoTerminalClient.new

    assert_raises(GeckoTerminalClient::ParseError) do
      client.stub(:request_json, { "data" => {} }) do
        client.fetch_pool_trades(network: "eth", pool_address: "0xpool")
      end
    end
  end

  test "fetch_pool_trades raises on malformed trade id" do
    payload = {
      "data" => [
        {
          "id" => "bad_id",
          "attributes" => {
            "tx_hash" => "0xtxhash",
            "block_timestamp" => "2026-04-13T00:00:00Z",
            "from_token_address" => "0xbase",
            "to_token_address" => "0xquote",
            "from_token_amount" => "2",
            "to_token_amount" => "4000"
          }
        }
      ]
    }

    client = GeckoTerminalClient.new

    assert_raises(GeckoTerminalClient::ParseError) do
      client.stub(:request_json, payload) do
        client.fetch_pool_trades(network: "eth", pool_address: "0xpool")
      end
    end
  end

  test "fetch_pool_trades raises when trade item is not a hash" do
    payload = { "data" => [ "not-a-hash" ] }
    client = GeckoTerminalClient.new

    assert_raises(GeckoTerminalClient::ParseError) do
      client.stub(:request_json, payload) do
        client.fetch_pool_trades(network: "eth", pool_address: "0xpool")
      end
    end
  end

  test "fetch_pool_trades raises when trade item misses id or attributes" do
    payload = {
      "data" => [
        {
          "id" => "eth_1_0xtxhash_10_123456"
        }
      ]
    }
    client = GeckoTerminalClient.new

    assert_raises(GeckoTerminalClient::ParseError) do
      client.stub(:request_json, payload) do
        client.fetch_pool_trades(network: "eth", pool_address: "0xpool")
      end
    end
  end

  test "fetch_token_usd_price returns normalized token price fields" do
    payload = {
      "data" => {
        "attributes" => {
          "token_prices" => {
            "0xquote" => "1.23"
          }
        }
      }
    }

    client = GeckoTerminalClient.new
    result = client.stub(:request_json, payload) do
      client.fetch_token_usd_price(network: "eth", token_address: "0xQUOTE")
    end

    assert_equal "0xquote", result[:token_address]
    assert_equal "1.23", result[:usd_price]
    assert_equal "https://api.geckoterminal.com/api/v2/simple/networks/eth/token_price/0xquote", result[:source_url]
  end

  test "fetch_token_usd_price raises when token_prices map is missing" do
    client = GeckoTerminalClient.new

    assert_raises(GeckoTerminalClient::ParseError) do
      client.stub(:request_json, { "data" => {} }) do
        client.fetch_token_usd_price(network: "eth", token_address: "0xquote")
      end
    end
  end

  test "fetch_token_usd_price raises when token key is missing in token_prices" do
    payload = {
      "data" => {
        "attributes" => {
          "token_prices" => {
            "0xother" => "9.99"
          }
        }
      }
    }
    client = GeckoTerminalClient.new

    assert_raises(GeckoTerminalClient::ParseError) do
      client.stub(:request_json, payload) do
        client.fetch_token_usd_price(network: "eth", token_address: "0xquote")
      end
    end
  end

  test "parse_response returns parsed json on success" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, '{"data":{"ok":true}}')

    client = GeckoTerminalClient.new
    parsed = client.send(:parse_response, response)

    assert_equal({ "data" => { "ok" => true } }, parsed)
  end

  test "parse_response raises rate limited error on 429" do
    response = Net::HTTPTooManyRequests.new("1.1", "429", "Too Many Requests")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, '{"errors":[{"title":"rate limited"}]}')

    client = GeckoTerminalClient.new

    error = assert_raises(GeckoTerminalClient::RateLimitedError) do
      client.send(:parse_response, response)
    end

    assert_equal "rate limited", error.message
  end

  test "parse_response raises upstream error on non-429 failure" do
    response = Net::HTTPBadGateway.new("1.1", "502", "Bad Gateway")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, '{"errors":[{"title":"bad gateway"}]}')

    client = GeckoTerminalClient.new

    error = assert_raises(GeckoTerminalClient::UpstreamError) do
      client.send(:parse_response, response)
    end

    assert_equal "bad gateway", error.message
    assert_equal 502, error.status
  end

  test "perform_get wraps timeout errors as upstream timeout" do
    client = GeckoTerminalClient.new
    uri = URI("https://api.geckoterminal.com/api/v2/simple/networks/eth/token_price/0xquote")

    Net::HTTP.stub(:start, ->(*) { raise Timeout::Error, "timed out" }) do
      error = assert_raises(GeckoTerminalClient::UpstreamError) do
        client.send(:perform_get, uri)
      end

      assert_equal 504, error.status
      assert_includes error.message, "timed out"
    end
  end

  test "perform_get returns response from http request block" do
    client = GeckoTerminalClient.new
    uri = URI("https://api.geckoterminal.com/api/v2/simple/networks/eth/token_price/0xquote")
    expected_response = Net::HTTPOK.new("1.1", "200", "OK")
    expected_response.instance_variable_set(:@read, true)
    expected_response.instance_variable_set(:@body, '{"ok":true}')

    fake_http = Object.new
    fake_http.define_singleton_method(:request) { |_request| expected_response }

    Net::HTTP.stub(:start, ->(*, &block) { block.call(fake_http) }) do
      response = client.send(:perform_get, uri)
      assert_equal expected_response, response
    end
  end

  test "perform_get wraps socket errors as upstream network error" do
    client = GeckoTerminalClient.new
    uri = URI("https://api.geckoterminal.com/api/v2/simple/networks/eth/token_price/0xquote")

    Net::HTTP.stub(:start, ->(*) { raise SocketError, "socket failed" }) do
      error = assert_raises(GeckoTerminalClient::UpstreamError) do
        client.send(:perform_get, uri)
      end

      assert_equal 502, error.status
      assert_includes error.message, "socket failed"
    end
  end

  test "request_json builds uri and delegates response parsing" do
    client = GeckoTerminalClient.new
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, '{"data":{"value":1}}')

    result = client.stub(:perform_get, response) do
      client.send(:request_json, "/simple/networks/eth/token_price/0xquote")
    end

    assert_equal({ "data" => { "value" => 1 } }, result)
  end

  test "parse_swap_log_index returns nil when swap log index is non-integer" do
    client = GeckoTerminalClient.new

    parsed = client.send(:parse_swap_log_index, "eth_1_0xtxhash_notanint_123456")
    assert_nil parsed
  end

  test "parse_json_body raises parse error for invalid json" do
    client = GeckoTerminalClient.new

    assert_raises(GeckoTerminalClient::ParseError) do
      client.send(:parse_json_body, "{not-json}")
    end
  end

  test "error_title_from_body returns nil for invalid json body" do
    client = GeckoTerminalClient.new

    assert_nil client.send(:error_title_from_body, "{not-json}")
  end
end
