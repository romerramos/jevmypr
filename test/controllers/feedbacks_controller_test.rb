require "test_helper"

class FeedbacksControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
    stub_github_repositories("acme/web")
    @assessment = users(:one).pr_assessments.create!(repository: repositories(:web), head_sha: "sha-7", repo_full_name: "acme/web", pr_number: 7, pr_title: "Fix login redirect",
                                                     pr_url: "https://github.com/acme/web/pull/7", choice: "no")
  end

  test "the verdict page asks whether Jev got it right" do
    get assessment_path(@assessment)

    assert_select "turbo-frame#feedback" do
      assert_select "form[action=?] button", assessment_feedback_path(@assessment), text: /Agree/
      assert_select "a[href=?]", edit_assessment_feedback_path(@assessment), text: /Disagree/
    end
  end

  test "agreeing saves Jev's verdict as the vote" do
    patch assessment_feedback_path(@assessment), params: { feedback: { choice: "no" } }

    assert_redirected_to assessment_path(@assessment)
    assert users(:one).feedbacks.find_by!(pr_assessment: @assessment).agreed?
    follow_redirect!
    assert_select "turbo-frame#feedback", text: /You agreed with Jev/
  end

  test "disagreeing offers the other two verdicts and a reason" do
    get edit_assessment_feedback_path(@assessment)

    assert_select "turbo-frame#feedback form[action=?]", assessment_feedback_path(@assessment) do
      assert_select "input[type=radio][name='feedback[choice]']", 2
      assert_select "input[type=radio][value=no]", 0
      assert_select "textarea[name='feedback[reason]']"
    end
  end

  test "disagreeing saves what it should have been and why" do
    patch assessment_feedback_path(@assessment), params: { feedback: { choice: "yes", reason: "It touches auth." } }

    feedback = users(:one).feedbacks.find_by!(pr_assessment: @assessment)
    assert_equal [ "yes", "It touches auth." ], feedback.values_at(:choice, :reason)
    follow_redirect!
    assert_select "turbo-frame#feedback", text: /needed a human review/i
    assert_select "turbo-frame#feedback", text: /It touches auth\./
  end

  test "disagreeing without picking a verdict asks again" do
    patch assessment_feedback_path(@assessment), params: { feedback: { reason: "Hmm" } }

    assert_response :unprocessable_entity
    assert_select "turbo-frame#feedback .text-error", text: /Pick what the verdict should have been/
    assert_not users(:one).feedbacks.exists?(pr_assessment: @assessment)
  end

  test "changing your mind clears the vote" do
    users(:one).feedbacks.new(pr_assessment: @assessment).record!(choice: "yes", reason: "Risky")

    delete assessment_feedback_path(@assessment)

    assert_redirected_to assessment_path(@assessment)
    assert_not users(:one).feedbacks.exists?(pr_assessment: @assessment)
  end

  test "you cannot vote on another user's private legacy verdict" do
    other = users(:two).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 8, pr_title: "Other",
                                              pr_url: "https://github.com/acme/web/pull/8", choice: "no")

    patch assessment_feedback_path(other), params: { feedback: { choice: "yes" } }

    assert_response :not_found
    assert_empty other.feedbacks
  end

  test "the verdicts list sums up your votes" do
    users(:one).feedbacks.new(pr_assessment: @assessment).record!(choice: "yes")
    docs = users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 9, pr_title: "Docs",
                                             pr_url: "https://github.com/acme/web/pull/9", choice: "no")
    users(:one).feedbacks.new(pr_assessment: docs).record!(choice: "no")

    get assessments_path

    assert_select "p", text: /You agreed with 1 of 2 verdicts you rated/
    assert_select "p", text: /1 needed more review than Jev said/
  end
end
