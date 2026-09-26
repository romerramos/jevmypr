require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.mock_auth[:github] = nil
    OmniAuth.config.test_mode = false
  end

  test "new shows the sign-in page with a blank triage tag" do
    get new_session_path

    assert_response :success
    assert_select "h1", "Does this PR need a human?"
    assert_select ".triage-tag__strip", 3
  end

  test "new redirects signed-in users to the picker" do
    sign_in_as users(:one)

    get new_session_path

    assert_redirected_to repositories_path
  end

  test "signing in with GitHub creates the user and stores the encrypted token" do
    mock_github_auth(uid: "4242", login: "newcomer", token: "gho_new_token")

    assert_difference -> { User.count }, 1 do
      get github_callback_path
    end

    assert_redirected_to root_path
    assert cookies[:session_id].present?

    user = User.find_by!(github_uid: "4242")
    assert_equal "newcomer", user.login
    assert_equal "gho_new_token", user.github_token
    assert_equal Time.utc(2019, 5, 4, 10), user.github_created_at
    assert_not_includes user.ciphertext_for(:github_token), "gho_new_token"
  end

  test "signing in again updates the existing user's token and profile" do
    user = users(:one)
    mock_github_auth(uid: user.github_uid, login: "octocat-renamed", token: "gho_rotated")

    assert_no_difference -> { User.count } do
      get github_callback_path
    end

    user.reload
    assert_equal "octocat-renamed", user.login
    assert_equal "gho_rotated", user.github_token
  end

  test "preview sign-in is not available outside development" do
    assert_not DevelopmentPreview.enabled?

    post preview_session_path

    assert_response :not_found
    assert_nil cookies[:session_id]
  end

  test "failure sends the user back to sign in with an explanation" do
    get auth_failure_path(message: "access_denied")

    assert_redirected_to new_session_path
    assert_match "access denied", flash[:alert]
  end

  test "destroy signs out" do
    sign_in_as users(:one)

    delete session_path

    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]
  end

  private
    def mock_github_auth(uid:, login:, token:)
      OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
        provider: "github",
        uid: uid,
        info: { nickname: login, name: "Test #{login}", image: "https://avatars.example/#{uid}" },
        credentials: { token: token },
        extra: { raw_info: { created_at: "2019-05-04T10:00:00Z" } }
      )
    end
end
