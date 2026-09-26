require "test_helper"

class Jev::ClientTest < ActiveSupport::TestCase
  URL = Jev::Client::URL

  setup do
    @client = Jev::Client.new(api_key: "test-key", retry_interval: 0)
  end

  test "ask posts state, model and questions with the bearer key and returns the answers" do
    stub = stub_request(:post, URL)
      .with(
        headers: { "Authorization" => "Bearer test-key", "Content-Type" => "application/json" },
        body: { state: "hello", model: "jev-latest", questions: { q: { type: "noul" } } }.to_json
      )
      .to_return(json_response({ model: "jev-1.13.0", answers: { q: { type: "noul", probability: 0.9 } }, usage: { input_tokens: 3 } }))

    response = @client.ask(state: "hello", questions: { q: { type: "noul" } })

    assert_requested stub
    assert_equal "jev-1.13.0", response.model
    assert_equal 0.9, response.answers.dig("q", "probability")
  end

  test "retries 429 and 529 before succeeding" do
    stub_request(:post, URL)
      .to_return(json_response({}, status: 429))
      .then.to_return(json_response({}, status: 529))
      .then.to_return(json_response({ model: "jev", answers: {}, usage: {} }))

    assert_equal "jev", @client.ask(state: "x", questions: {}).model
    assert_requested :post, URL, times: 3
  end

  test "gives up after repeated overload responses" do
    stub_request(:post, URL).to_return(json_response({}, status: 529))

    assert_raises(Jev::Client::Unavailable) { @client.ask(state: "x", questions: {}) }
    assert_requested :post, URL, times: 4
  end

  test "maps 401 and 422 to specific errors" do
    stub_request(:post, URL).to_return(json_response({ error: "bad key" }, status: 401))
    assert_raises(Jev::Client::Unauthorized) { @client.ask(state: "x", questions: {}) }

    stub_request(:post, URL).to_return(json_response({ error: "state is required" }, status: 422))
    error = assert_raises(Jev::Client::ValidationError) { @client.ask(state: "x", questions: {}) }
    assert_match "state is required", error.message
  end

  test "a request bigger than Jev's context window raises TooLarge, other 400s a plain Error" do
    stub_request(:post, URL).to_return(json_response({ error_type: "max_tokens_exceeded" }, status: 400))
    assert_raises(Jev::Client::TooLarge) { @client.ask(state: "x", questions: {}) }

    stub_request(:post, URL).to_return(json_response({ error: "bad question" }, status: 400))
    error = assert_raises(Jev::Client::Error) { @client.ask(state: "x", questions: {}) }
    assert_not_kind_of Jev::Client::TooLarge, error
    assert_match "bad question", error.message
  end

  test "network failures become Unavailable" do
    stub_request(:post, URL).to_timeout

    assert_raises(Jev::Client::Unavailable) { @client.ask(state: "x", questions: {}) }
  end

  test "requires an API key" do
    assert_raises(Jev::Client::Unauthorized) { Jev::Client.new(api_key: nil) }
  end
end
