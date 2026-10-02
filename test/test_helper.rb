ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/api_stubs"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
    def json_response(body, status: 200, headers: {})
      { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" }.merge(headers) }
    end
  end
end

WebMock.disable_net_connect!(allow_localhost: true)

# CI has no master key, so credentials are empty there. Jev calls are stubbed; any key will do.
ENV["TYPESAFE_API_KEY"] = "test-jev-api-key"

ActiveSupport.on_load(:action_dispatch_integration_test) do
  setup { ActionController::Base.cache_store.clear }
end
