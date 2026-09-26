require "application_system_test_case"

class AccountMenuTest < ApplicationSystemTestCase
  test "signing out from the account menu" do
    stub_github_repositories("acme/web")
    sign_in_with_github users(:one)
    assert_current_path repositories_path

    click_on "Account menu"
    within("#account-menu") { click_on "Sign out" }

    assert_current_path new_session_path
    assert_selector "h1", text: "Does this PR need a human?"
  end

  test "deleting my data from the account menu" do
    stub_github_repositories("acme/web")
    sign_in_with_github users(:one)

    click_on "Account menu"
    accept_confirm(/This can't be undone/) do
      within("#account-menu") { click_on "Delete my data" }
    end

    assert_text "Your account, verdicts and pins are deleted"
    assert_current_path new_session_path
    assert_not User.exists?(users(:one).id)
  end
end
