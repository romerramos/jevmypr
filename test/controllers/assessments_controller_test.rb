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
    assert_equal "sha-7", assessment.head_sha
    assert_equal [ "acme/web", 7, "yes", "jev-1.13.0" ], [ assessment.repo_full_name, assessment.pr_number, assessment.choice, assessment.jev_model ]
    assert_equal 0.7, assessment.probabilities["yes"]
    assert_equal "app/controllers/sessions_controller.rb", assessment.files.first["filename"]

    follow_redirect!
    assert_select "h1", "Get a human on this."
    assert_select ".triage-tag__strip.is-torn", 2
    assert_select ".triage-tag__strip--red.is-kept"
    assert_select ".verdict-badge.verdict-badge--yes", text: /Human review/
    assert_select "a[href=?]", "https://github.com/acme/web/pull/7", text: /Open on GitHub/
    assert_select "main progress", 3
    assert_select "form.ask-jev[action=?] button", "/repositories/acme/web/pull_requests/7/assessments", text: /Ask\s*Jev\s*again/
    assert_select ".ask-jev-overlay"
  end

  test "stores the token counts Jev reports" do
    stub_github_pull_request
    stub_jev(choice: "no")

    post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)

    assert_equal [ 10, 2 ], PrAssessment.last.values_at(:input_tokens, :output_tokens)
  end

  test "a used-up weekly quota stops before any GitHub or Jev call" do
    limit = JevAllowance::LIMITS.weekly_verdicts_per_user
    limit.times { |i| create_assessment(users(:one), title: "PR #{i}", number: i, created_at: 1.day.ago) }

    assert_no_difference -> { PrAssessment.count } do
      post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)
    end

    assert_redirected_to repository_pull_requests_path(owner: "acme", repo: "web")
    assert_match "used all #{limit} verdicts", flash[:alert]
    assert_not_requested :any, /api\.github\.com|typesafe/
  end

  test "asking is limited to a few times a minute per user" do
    stub_github_pull_request
    stub_jev(choice: "no")

    5.times { post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7) }
    assert_difference -> { PrAssessment.count }, 0 do
      post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)
    end
    assert_match "a lot of pull requests at once", flash[:alert]
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

  test "a pull request too big for Jev gets a friendly message and is marked too big" do
    stub_github_pull_request
    stub_request(:post, Jev::Client::URL).to_return(json_response({ error_type: "max_tokens_exceeded" }, status: 400))

    assert_no_difference -> { PrAssessment.count } do
      post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)
    end

    assert_redirected_to repository_pull_requests_path(owner: "acme", repo: "web")
    assert_match "too big for Jev", flash[:alert]
    assert_no_match "HTTP 400", flash[:alert]
    assert_equal [ "acme/web", 7, "sha-7" ], users(:one).oversized_pull_requests.sole.values_at(:repo_full_name, :pr_number, :head_sha)
  end

  test "asking again about an unchanged pull request that's too big doesn't call Jev" do
    users(:one).oversized_pull_requests.create!(repo_full_name: "acme/web", pr_number: 7, head_sha: "sha-7")
    stub_github_pull_request

    post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)

    assert_match "too big for Jev", flash[:alert]
    assert_not_requested :post, Jev::Client::URL
  end

  test "a too-big pull request that changed since can be asked about again" do
    users(:one).oversized_pull_requests.create!(repo_full_name: "acme/web", pr_number: 7, head_sha: "old-sha")
    stub_github_pull_request
    stub_jev(choice: "no")

    assert_difference -> { PrAssessment.count }, 1 do
      post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)
    end
  end

  test "a missing pull request returns to the picker" do
    stub_request(:get, "#{ApiStubs::GITHUB}/repos/acme/web/pulls/99").to_return(json_response({}, status: 404))

    post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 99)

    assert_redirected_to repository_pull_requests_path(owner: "acme", repo: "web")
    assert_match "couldn't find", flash[:alert]
  end

  test "index lists the user's verdicts, newest first" do
    user = users(:one)
    create_assessment(user, title: "Older", created_at: 2.days.ago)
    create_assessment(user, title: "Newer")
    create_assessment(users(:two), title: "Not mine")

    get assessments_path

    assert_select "h1", "Your verdicts"
    assert_equal [ "Newer", "Older" ], css_select(".list-row .font-medium").map(&:text)
    assert_select "nav[aria-label=Pagination]", 0
  end

  test "index paginates 20 per page with newer and older links" do
    25.times { |i| create_assessment(users(:one), title: "PR #{i}", number: i, created_at: i.minutes.ago) }

    get assessments_path

    assert_select ".list-row", 20
    assert_select "nav[aria-label=Pagination]", text: /1–20 of 25/
    assert_select "a[rel=next][href=?]", assessments_path(page: 2), text: /Older/
    assert_select "span.btn-disabled", text: /Newer/

    get assessments_path(page: 2)
    assert_select ".list-row", 5
    assert_select "nav[aria-label=Pagination]", text: /21–25 of 25/
    assert_select "a[rel=prev]", text: /Newer/
  end

  test "index searches by title, repository or #number and filters by verdict" do
    user = users(:one)
    create_assessment(user, title: "Rotate API keys", repo: "acme/vault", number: 12, choice: "yes")
    create_assessment(user, title: "Fix typo", repo: "acme/docs", number: 7, choice: "no")
    create_assessment(user, title: "Refactor client", repo: "acme/web", number: 9, choice: "llm_enough")

    get assessments_path(q: "rotate"), headers: { "Turbo-Frame" => "verdicts" }
    assert_equal [ "Rotate API keys" ], titles

    get assessments_path(q: "#7")
    assert_equal [ "Fix typo" ], titles

    get assessments_path(q: "acme web")
    assert_equal [ "Refactor client" ], titles

    get assessments_path(verdict: "yes")
    assert_equal [ "Rotate API keys" ], titles
    assert_select "input[type=radio][name=verdict][value=yes][checked]"
    assert_select "label", text: /Human review\s*1/
    assert_select "label", text: /All\s*3/

    get assessments_path(q: "nothing like this")
    assert_select "turbo-frame#verdicts", text: /No verdicts match “nothing like this”/
  end

  test "verdict page links back to the repository's pull requests" do
    assessment = users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 1, pr_title: "x", pr_url: "https://github.com/acme/web/pull/1", choice: "no")

    get assessment_path(assessment)

    assert_select "a[href=?]", "/repositories/acme/web/pull_requests", text: /Pull requests in acme\/web/
    assert_select "p", text: /That verdict cost Jev a few tokens/, count: 0
  end

  test "users can only see their own assessments" do
    theirs = users(:two).pr_assessments.create!(repo_full_name: "other/repo", pr_number: 1, pr_title: "Private", pr_url: "https://github.com/other/repo/pull/1", choice: "no")

    get assessment_path(theirs)

    assert_response :not_found
  end

  private
    def create_assessment(user, title:, repo: "acme/web", number: 1, choice: "no", created_at: Time.current)
      user.pr_assessments.create!(repo_full_name: repo, pr_number: number, pr_title: title,
                                  pr_url: "https://github.com/#{repo}/pull/#{number}", choice: choice, created_at: created_at)
    end

    def titles = css_select(".list-row .font-medium").map(&:text)
end
