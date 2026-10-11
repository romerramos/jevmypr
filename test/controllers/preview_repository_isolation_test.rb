require "test_helper"

class PreviewRepositoryIsolationTest < ActionDispatch::IntegrationTest
  setup do
    @original_environment = Rails.env
    @original_preview_mode = ENV["PREVIEW_MODE"]
    @live_repository = repositories(:web)
    @live_repository.update!(full_name: "live-org/web")
    @live = users(:one).pr_assessments.create!(repository: @live_repository, repo_full_name: "live-org/web",
      pr_number: 7, head_sha: "preview-7", pr_title: "Live-only snapshot", pr_url: "https://github.com/live-org/web/pull/7",
      choice: "yes", files: [ { "filename" => "live-only.rb" } ])
    @preview_user = DevelopmentPreview.user
    @sample_repository = Repository.from_github!(Github::PreviewClient.new.repository("acme/web"))
    @sample = @preview_user.pr_assessments.create!(repository: @sample_repository, repo_full_name: "acme/web",
      pr_number: 7, head_sha: "preview-7", pr_title: "Sample-only snapshot", pr_url: "https://github.com/acme/web/pull/7",
      choice: "no", files: [ { "filename" => "sample-only.rb" } ], jev_model: "preview")
    @live_vote = users(:one).feedbacks.new(pr_assessment: @live)
    @live_vote.record!(choice: "llm_enough", reason: "Live-only private reason")
    @sample_vote = @preview_user.feedbacks.new(pr_assessment: @sample)
    @sample_vote.record!(choice: "yes", reason: "Sample-only private reason")
    stub_github_repositories("acme/web")
    stub_github_pull_request(head_sha: "preview-7")
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Live current PR", head_sha: "preview-7") ])
    Rails.env = "development"
    ENV["PREVIEW_MODE"] = "1"
  end

  teardown do
    Rails.env = @original_environment
    ENV["PREVIEW_MODE"] = @original_preview_mode
  end

  test "preview cannot read, reuse or rename a live repository with the same absolute ID" do
    assert_equal [ 101, -101 ], [ @live_repository.github_id, @sample_repository.github_id ]
    sign_in_as @preview_user
    get assessments_path
    assert_select ".list-row", text: /Sample-only snapshot/
    assert_hidden @live, @live_vote
    get repositories_path
    assert_hidden @live, @live_vote
    get repository_pull_requests_path(owner: "acme", repo: "web")
    assert_select "a[href=?]", assessment_path(@sample), count: 1
    assert_select "a[href=?]", assessment_path(@live), count: 0

    assert_no_difference [ -> { PrAssessment.count }, -> { JevRequest.count } ] do
      post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)
      assert_redirected_to assessment_path(@sample)
    end
    get assessment_path(@live)
    assert_hidden @live, @live_vote
    get edit_assessment_feedback_path(@live)
    assert_select "textarea", count: 0
    assert_no_difference -> { Feedback.count } do
      patch assessment_feedback_path(@live), params: { feedback: { choice: "no", reason: "Wrong mode" } }
      delete assessment_feedback_path(@live)
    end
    assert_equal "Live-only private reason", @live_vote.reload.reason
    assert_equal "live-org/web", @live_repository.reload.full_name
    assert_not_requested :any, %r{\Ahttps://(?:api\.github\.com|api\.typesafe\.ai)/}
  end

  test "live access cannot read, reuse or rename a sample repository with the same absolute ID" do
    @sample_repository.update!(full_name: "sample-only/unchanged")
    sign_in_as users(:one)
    get assessments_path
    assert_select ".list-row", text: /Live-only snapshot/
    assert_hidden @sample, @sample_vote
    get repositories_path
    assert_hidden @sample, @sample_vote
    get repository_pull_requests_path(owner: "acme", repo: "web")
    assert_select "a[href=?]", assessment_path(@live), count: 1
    assert_select "a[href=?]", assessment_path(@sample), count: 0

    assert_no_difference [ -> { PrAssessment.count }, -> { JevRequest.count } ] do
      post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)
      assert_redirected_to assessment_path(@live)
    end
    get assessment_path(@sample)
    assert_hidden @sample, @sample_vote
    get edit_assessment_feedback_path(@sample)
    assert_select "textarea", count: 0
    assert_no_difference -> { Feedback.count } do
      patch assessment_feedback_path(@sample), params: { feedback: { choice: "llm_enough", reason: "Wrong mode" } }
      delete assessment_feedback_path(@sample)
    end
    assert_equal "Sample-only private reason", @sample_vote.reload.reason
    assert_equal "sample-only/unchanged", @sample_repository.reload.full_name
    assert_not_requested :get, "#{ApiStubs::GITHUB}/repositories/-101"
    assert_not_requested :post, Jev::Client::URL
  end

  private
    def assert_hidden(assessment, feedback)
      assert_not_includes response.body, assessment.pr_title
      assert_not_includes response.body, assessment.files.sole["filename"]
      assert_not_includes response.body, feedback.reason
    end
end
