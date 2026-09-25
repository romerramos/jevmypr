require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "home shows a blank triage tag with every strip" do
    get root_path

    assert_response :success
    assert_select "h1", "Does this PR need a human?"
    assert_select ".triage-tag__strip", 3
    assert_select ".triage-tag__strip.is-torn", 0
  end

  test "home previews a verdict by tearing off the strips below it" do
    get root_path(verdict: "yes")

    assert_select ".triage-tag__strip.is-torn", 2
    assert_select ".triage-tag__strip--red:not(.is-torn)"
  end
end
