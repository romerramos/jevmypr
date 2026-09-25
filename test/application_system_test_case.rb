require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include ApiStubs

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ]
  Capybara.enable_aria_label = true

  def sign_in_with_github(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github", uid: user.github_uid,
      info: { nickname: user.login, name: user.name, image: nil },
      credentials: { token: "gho_system_test" }
    )
    visit "/auth/github/callback"
  end

  teardown do
    OmniAuth.config.mock_auth[:github] = nil
    OmniAuth.config.test_mode = false
  end
end
