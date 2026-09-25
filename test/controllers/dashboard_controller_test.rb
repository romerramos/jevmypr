require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  test "requires sign-in" do
    get root_path

    assert_redirected_to new_session_path
  end

  test "shows the signed-in user and the account menu" do
    sign_in_as users(:one)

    get root_path

    assert_response :success
    assert_select "h1", "Hi, The Octocat"
    assert_select "#account-menu", text: /Signed in as octocat/
  end
end
