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

  test "deletion removes every personal record and requester link but preserves shared verdicts and spend" do
    user = users(:one)
    sign_in_as user
    stub_github_pull_request
    stub_jev(choice: "yes")
    post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)
    shared = PrAssessment.last
    request = shared.jev_request
    legacy = user.pr_assessments.create!(repo_full_name: "acme/web", pr_number: 8, pr_title: "Legacy",
      pr_url: "https://github.com/acme/web/pull/8", choice: "no", input_tokens: 3_000, output_tokens: 1)
    legacy_usage = user.jev_requests.create!(state: "succeeded", sent_at: Time.current, input_tokens: 3_000, output_tokens: 1)
    user.feedbacks.new(pr_assessment: shared).record!(choice: "no", reason: "Delete my reason")
    user.feedbacks.new(pr_assessment: legacy).record!(choice: "yes", reason: "Delete legacy vote")
    users(:two).feedbacks.new(pr_assessment: shared).record!(choice: "llm_enough", reason: "Teammate's reason stays")
    user.pinned_repositories.create!(full_name: "acme/web")
    users(:two).pinned_repositories.create!(full_name: "acme/web")
    user.oversized_pull_requests.create!(repo_full_name: "acme/web", pr_number: 9, head_sha: "legacy-big")
    marker = repositories(:web).oversized_pull_requests.create!(repo_full_name: "acme/web", pr_number: 10, head_sha: "shared-big")
    2.times { user.sessions.create! }
    teammate_session = users(:two).sessions.create!
    old_cookie = cookies[:session_id]
    assert_in_delta 0.000126546, JevAllowance.new(users(:two)).monthly_spend_usd, 1e-12

    assert_difference -> { User.count } => -1, -> { PrAssessment.count } => -1,
      -> { Feedback.count } => -2, -> { Session.count } => -3, -> { OversizedPullRequest.count } => -1 do
      assert_no_difference -> { JevRequest.count } do
        delete account_path
      end
    end

    assert_nil shared.reload.user_id
    assert_equal repositories(:web), shared.repository
    assert_equal "ana", shared.pr_author # GitHub metadata is not deleted account attribution.
    assert shared.files.sole["filename"].present?
    assert_nil request.reload.user_id
    assert_nil legacy_usage.reload.user_id
    assert_not PrAssessment.exists?(legacy.id)
    assert OversizedPullRequest.exists?(marker.id)
    assert Session.exists?(teammate_session.id)
    assert_not Session.exists?(user_id: user.id)
    assert_not Feedback.exists?(user_id: user.id)
    assert_not PinnedRepository.exists?(user_id: user.id)
    assert_in_delta 0.000126546, JevAllowance.new(users(:two)).monthly_spend_usd, 1e-12
    assert_match "Shared repository verdicts stay", flash[:notice]

    cookies[:session_id] = old_cookie
    get assessment_path(shared)
    assert_redirected_to new_session_path

    sign_in_as users(:two)
    stub_github_repository
    get assessment_path(shared)
    assert_select "#feedback blockquote", "Teammate's reason stays"
    assert_not_includes response.body, "Delete my reason"
    assert users(:two).pinned_repositories.exists?(full_name: "acme/web")
  end

  test "requires sign-in" do
    assert_no_difference -> { User.count } do
      delete account_path
    end
    assert_redirected_to new_session_path
  end
end
