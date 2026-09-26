require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  test "deleting an account removes the user and everything stored for them, and signs out" do
    user = users(:one)
    user.pr_assessments.create!(repo_full_name: "acme/web", pr_number: 1, pr_title: "x", pr_url: "https://github.com/acme/web/pull/1", choice: "no")
    user.pinned_repositories.create!(full_name: "acme/web")
    sign_in_as user

    assert_difference -> { User.count } => -1, -> { PrAssessment.count } => -1, -> { PinnedRepository.count } => -1, -> { Session.count } => -1 do
      delete account_path
    end

    assert_redirected_to new_session_path
    assert_match "are deleted", flash[:notice]
    assert_empty cookies[:session_id]
    assert users(:two).reload.persisted?
  end

  test "requires sign-in" do
    assert_no_difference -> { User.count } do
      delete account_path
    end
    assert_redirected_to new_session_path
  end
end
