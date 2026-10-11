require "test_helper"

class HealthControllerTest < ActionDispatch::IntegrationTest
  test "/up answers with the running version for bin/update's health check" do
    get rails_health_check_path

    assert_response :success
    assert_equal Rails.application.config.x.version, response.headers[ReleaseUpdate::VERSION_HEADER]
  end
end
