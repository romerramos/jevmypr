require "test_helper"

class AssessmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
  end

  test "asks Jev about the pull request, stores the verdict and shows it" do
    stub_github_pull_request
    stub_jev(choice: "yes")

    assert_difference -> { users(:one).pr_assessments.count }, 1 do
      post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)
    end

    assessment = PrAssessment.last
    assert_redirected_to assessment_path(assessment)
    assert_equal [ "acme/web", 7, "yes", "jev-1.13.0" ], [ assessment.repo_full_name, assessment.pr_number, assessment.choice, assessment.jev_model ]
    assert_equal 0.7, assessment.probabilities["yes"]
    assert_equal "app/controllers/sessions_controller.rb", assessment.files.first["filename"]

    follow_redirect!
    assert_select "h1", "Get a human on this."
    assert_select ".triage-tag__strip.is-torn", 2
    assert_select "a[href=?]", "https://github.com/acme/web/pull/7", text: /Open on GitHub/
    assert_select "progress", 3
  end

  test "a Jev failure returns to the picker with the reason" do
    stub_github_pull_request
    stub_request(:post, Jev::Client::URL).to_return(json_response({ error: "bad key" }, status: 401))

    assert_no_difference -> { PrAssessment.count } do
      post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)
    end

    assert_redirected_to repository_pull_requests_path(owner: "acme", repo: "web")
    assert_match "Jev rejected the API key", flash[:alert]
  end

  test "a missing pull request returns to the picker" do
    stub_request(:get, "#{ApiStubs::GITHUB}/repos/acme/web/pulls/99").to_return(json_response({}, status: 404))

    post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 99)

    assert_redirected_to repository_pull_requests_path(owner: "acme", repo: "web")
    assert_match "couldn't find", flash[:alert]
  end

  test "index lists the user's verdicts, newest first" do
    user = users(:one)
    user.pr_assessments.create!(repo_full_name: "acme/web", pr_number: 1, pr_title: "Older", pr_url: "https://github.com/acme/web/pull/1", choice: "no", created_at: 2.days.ago)
    user.pr_assessments.create!(repo_full_name: "acme/web", pr_number: 2, pr_title: "Newer", pr_url: "https://github.com/acme/web/pull/2", choice: "yes")
    users(:two).pr_assessments.create!(repo_full_name: "other/repo", pr_number: 1, pr_title: "Not mine", pr_url: "https://github.com/other/repo/pull/1", choice: "no")

    get assessments_path

    assert_select "h1", "Your verdicts"
    assert_equal [ "Newer", "Older" ], css_select(".list-row .font-medium").map(&:text)
  end

  test "verdict page links back to the repository's pull requests" do
    assessment = users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 1, pr_title: "x", pr_url: "https://github.com/acme/web/pull/1", choice: "no")

    get assessment_path(assessment)

    assert_select "a[href=?]", "/repositories/acme/web/pull_requests", text: /Pull requests in acme\/web/
  end

  test "users can only see their own assessments" do
    theirs = users(:two).pr_assessments.create!(repo_full_name: "other/repo", pr_number: 1, pr_title: "Private", pr_url: "https://github.com/other/repo/pull/1", choice: "no")

    get assessment_path(theirs)

    assert_response :not_found
  end
end
