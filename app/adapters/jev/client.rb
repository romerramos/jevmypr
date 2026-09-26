require "faraday"
require "faraday/retry"

module Jev
  # Talks to TypeSafe's Jev model. Docs: https://docs.typesafe.ai/api.md
  #
  #   Jev::Client.new.ask(state: "...", questions: { spam: { type: "noul", ... } })
  #   # => #<data Jev::Client::Response model="jev-1.13.0", answers={"spam" => {...}}, usage={...}>
  class Client
    class Error < StandardError; end
    class Unauthorized < Error; end
    class ValidationError < Error; end
    class Unavailable < Error; end
    class TooLarge < Error; end

    Response = Data.define(:model, :answers, :usage)

    URL = "https://api.typesafe.ai/v1/systemone"
    DEFAULT_MODEL = "jev-latest"
    RETRY_STATUSES = [ 429, 529 ].freeze

    def initialize(api_key: AppSecrets[:typesafe_api_key], retry_interval: 1)
      raise Unauthorized, "Missing Jev API key. Add typesafe.api_key with bin/rails credentials:edit." if api_key.blank?

      @connection = Faraday.new(url: URL) do |f|
        f.request :authorization, "Bearer", api_key
        f.request :json
        f.request :retry, max: 3, interval: retry_interval, backoff_factor: 2,
          methods: %i[post], retry_statuses: RETRY_STATUSES
        f.response :json
        f.options.timeout = 90
        f.options.open_timeout = 10
      end
    end

    def ask(state:, questions:, model: DEFAULT_MODEL)
      response = @connection.post("", { state: state, model: model, questions: questions })
      handle_errors!(response)

      Response.new(model: response.body["model"], answers: response.body["answers"], usage: response.body["usage"])
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise Unavailable, "Couldn't reach Jev (#{e.class.name.demodulize})."
    end

    private
      def handle_errors!(response)
        case response.status
        when 200..299 then nil
        when 400 then raise too_large_or_error(response)
        when 401 then raise Unauthorized, "Jev rejected the API key. Check typesafe.api_key in your credentials."
        when 422 then raise ValidationError, "Jev couldn't read the request: #{error_detail(response)}"
        when *RETRY_STATUSES then raise Unavailable, "Jev is busy right now (HTTP #{response.status}). Try again in a minute."
        else raise Error, "Jev returned HTTP #{response.status}: #{error_detail(response)}"
        end
      end

      # Jev answers HTTP 400 with e.g. { "error_type": "max_tokens_exceeded" } when the state doesn't fit its context window.
      def too_large_or_error(response)
        if response.body.to_s.match?(/max_tokens|context|too (long|large)/i)
          TooLarge.new("The request is bigger than Jev's context window.")
        else
          Error.new("Jev returned HTTP 400: #{error_detail(response)}")
        end
      end

      def error_detail(response)
        body = response.body
        detail = body.is_a?(Hash) ? (body["error"] || body["message"] || body["detail"] || body) : body
        detail.to_s.truncate(300)
      end
  end
end
