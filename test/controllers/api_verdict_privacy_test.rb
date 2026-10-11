require "test_helper"

# Verdicts for diffs sent to the open API belong to no repository or user: the web app never shows them.
class ApiVerdictPrivacyTest < ActionDispatch::IntegrationTest
  setup do
    @api = PrAssessment.create!(source: "api", diff_sha256: "abc123", expires_at: 1.day.from_now, pr_title: "Secret API change", choice: "yes")
    sign_in_as users(:one)
    stub_github_repositories("acme/web")
  end

  test "signed-in users can't open or vote on an API verdict" do
    get assessment_path(@api)
    assert_response :not_found

    get edit_assessment_feedback_path(@api)
    assert_response :not_found
  end

  test "lists of verdicts don't include API verdicts" do
    get assessments_path
    assert_response :success
    assert_no_match "Secret API change", response.body

    get repositories_path
    assert_response :success
    assert_no_match "Secret API change", response.body
  end
end
