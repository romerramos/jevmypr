require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "display name falls back to the GitHub login" do
    assert_equal "The Octocat", users(:one).display_name
    assert_equal "hubot", users(:two).display_name
  end
end
