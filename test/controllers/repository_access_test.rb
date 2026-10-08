require "test_helper"

class RepositoryAccessTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
    stub_github_repositories("acme/web")
    @shared = users(:one).pr_assessments.create!(repository: repositories(:web), repo_full_name: "acme/web",
      pr_number: 7, head_sha: "sha-7", pr_title: "Repository-only sample", pr_url: "https://github.com/acme/web/pull/7",
      choice: "no", files: [ { "filename" => "app/sample.rb" } ])
  end

  test "the owner can read a migrated private snapshot and vote while a teammate cannot" do
    legacy = users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 8, pr_title: "Private historical sample",
      pr_url: "https://github.com/acme/web/pull/8", choice: "no", head_sha: nil, created_at: 2.months.ago)
    vote = users(:one).feedbacks.create!(pr_assessment: legacy, choice: "yes", reason: "My migrated reason",
      voted_at: 1.month.ago, created_at: 2.months.ago)

    get assessment_path(legacy)
    assert_response :success
    assert_select "[aria-label='Verdict privacy']", text: /Private legacy verdict/
    assert_select "#feedback blockquote", "My migrated reason"
    get assessments_path
    assert_select ".list-row", text: /Private historical sample.*Private legacy/m
    assert_select "p", text: /1 needed more review/
    patch assessment_feedback_path(legacy), params: { feedback: { choice: "llm_enough", reason: "Edited privately" } }
    assert_equal "Edited privately", vote.reload.reason
    assert_nil legacy.reload.repository_id
    assert_requested :get, "#{ApiStubs::GITHUB}/repos/acme/web", times: 3,
      headers: { "Authorization" => "Bearer #{users(:one).github_token}" }

    sign_in_as users(:two)
    get assessments_path
    assert_no_private_history(legacy)
    get repositories_path
    assert_no_private_history(legacy)
    [ [ :get, assessment_path(legacy) ], [ :get, edit_assessment_feedback_path(legacy) ],
      [ :patch, assessment_feedback_path(legacy) ], [ :delete, assessment_feedback_path(legacy) ] ].each do |method, path|
      public_send(method, path, params: { feedback: { choice: "no", user_id: users(:one).id } })
      assert_response :not_found
    end
    assert_equal [ "llm_enough", "Edited privately" ], vote.reload.values_at(:choice, :reason)
    assert_nil legacy.reload.repository_id
  end

  test "GitHub revocation or failure denies even the owner's legacy direct ID and feedback" do
    legacy = users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 8, pr_title: "Private historical sample",
      pr_url: "https://github.com/acme/web/pull/8", choice: "no")
    vote = users(:one).feedbacks.new(pr_assessment: legacy)
    vote.record!(choice: "yes", reason: "Private reason")

    [ 404, 403, 500 ].each do |status|
      stub_request(:get, "#{ApiStubs::GITHUB}/repos/acme/web").to_return(json_response({}, status: status))
      get assessment_path(legacy)
      assert_no_private_history(legacy)
      get edit_assessment_feedback_path(legacy)
      assert_select "textarea", 0
      patch assessment_feedback_path(legacy), params: { feedback: { choice: "no" } }
      delete assessment_feedback_path(legacy)
      assert_equal "Private reason", vote.reload.reason
      assert_no_private_history(legacy)
    end
  end

  test "teammates keep distinct votes and reasons on the same shared result" do
    patch assessment_feedback_path(@shared), params: { feedback: { choice: "yes", reason: "First person's reason" } }
    sign_in_as users(:two)
    get assessment_path(@shared)
    assert_select "#feedback", text: /Did Jev get this right/
    assert_select "#feedback", text: /First person's reason/, count: 0

    patch assessment_feedback_path(@shared), params: { feedback: { choice: "llm_enough", reason: "Second person's reason", user_id: users(:one).id } }
    follow_redirect!
    assert_select "#feedback blockquote", "Second person's reason"
    get assessments_path
    assert_select "p", text: /You agreed with 0 of 1 verdict you rated/

    sign_in_as users(:one)
    get edit_assessment_feedback_path(@shared)
    assert_select "textarea", "First person's reason"
    delete assessment_feedback_path(@shared)
    assert_not users(:one).feedbacks.exists?(pr_assessment: @shared)
    assert_equal "Second person's reason", users(:two).feedbacks.find_by!(pr_assessment: @shared).reason
    assert_equal "no", @shared.reload.choice
  end

  test "revocation beats an earlier requester link, a pin and a stale repository list on every shared entry point" do
    users(:one).pinned_repositories.create!(full_name: "acme/web")
    users(:one).feedbacks.new(pr_assessment: @shared).record!(choice: "yes", reason: "Personal vote")
    get assessment_path(@shared)
    assert_select "#feedback blockquote", "Personal vote"
    stub_github_repository(token: users(:one).github_token, status: 404)

    [ assessments_path, repositories_path, assessment_path(@shared), edit_assessment_feedback_path(@shared),
      repository_pull_requests_path(owner: "acme", repo: "web") ].each do |path|
      get path
      assert_no_shared_data
    end
    assert_no_difference [ -> { Feedback.count }, -> { JevRequest.count }, -> { PrAssessment.count } ] do
      patch assessment_feedback_path(@shared), params: { feedback: { choice: "no" } }
      delete assessment_feedback_path(@shared)
      post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)
      post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7), params: { fresh: "1" }
    end
    assert_not_requested :post, Jev::Client::URL
    assert_equal "Personal vote", users(:one).feedbacks.sole.reason

    sign_in_as users(:two)
    get assessment_path(@shared)
    assert_select "h1", "Safe to merge without review."
    assert_select "#feedback", text: /Personal vote/, count: 0
  end

  test "GitHub errors and timeouts fail closed rather than rendering shared metadata or changing a vote" do
    [ 403, 429, 500 ].each do |status|
      stub_github_repository(status: status)
      get assessment_path(@shared)
      assert_no_shared_data
      get assessments_path
      assert_no_shared_data
      assert_no_difference -> { Feedback.count } do
        patch assessment_feedback_path(@shared), params: { feedback: { choice: "yes" } }
      end
    end
    stub_request(:get, "#{ApiStubs::GITHUB}/repositories/101").to_timeout
    get assessment_path(@shared)
    assert_no_shared_data
    assert_select "[role=alert]", text: /Couldn't reach GitHub/
  end

  test "a revoked token signs out and cannot read an old shared direct ID" do
    stub_github_repository(status: 401)
    get assessment_path(@shared)

    assert_no_shared_data
    assert_empty cookies[:session_id]
    assert_select "a[href=?]", new_session_path, text: /Sign in again/
  end

  test "a renamed repository keeps its stable history and links use the verified current name" do
    stub_github_repository("acme/renamed", github_id: 101)
    get assessment_path(@shared)

    assert_select "a[href=?]", "/repositories/acme/renamed/pull_requests", text: /Pull requests in acme\/renamed/
    assert_select "a[href=?]", "https://github.com/acme/renamed/pull/7", text: /Open on GitHub/
    assert_select "form.ask-jev[action=?]", "/repositories/acme/renamed/pull_requests/7/assessments"
    assert_equal "acme/renamed", repositories(:web).reload.full_name
    assert_equal "acme/web", @shared.reload.repo_full_name
    assert_not_requested :get, "#{ApiStubs::GITHUB}/repos/acme/web"
  end

  test "reusing an old name for a different repository cannot expose or reuse the original shared verdict" do
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Replacement repository PR") ], github_id: 909)
    stub_github_pull_request(title: "Replacement repository PR", github_id: 909)
    stub_request(:get, "#{ApiStubs::GITHUB}/repositories/101").to_return(json_response({}, status: 404))
    stub_jev(choice: "yes")

    get repository_pull_requests_path(owner: "acme", repo: "web")
    assert_no_shared_data
    assert_select "form.ask-jev[action=?]", "/repositories/acme/web/pull_requests/7/assessments"
    get assessment_path(@shared)
    assert_no_shared_data

    assert_difference -> { PrAssessment.count }, 1 do
      post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7)
    end
    assert_equal 909, PrAssessment.last.repository.github_id
    assert_equal 101, @shared.reload.repository.github_id
    assert_requested :post, Jev::Client::URL, times: 1
  end

  test "a name reused between repository lookup and the GraphQL picker response fails closed" do
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Wrong repository data") ], github_id: 909)
    stub_github_repository(github_id: 101)
    get repository_pull_requests_path(owner: "acme", repo: "web")

    assert_select "[role=alert]", text: /repository identity changed/
    assert_no_shared_data
    assert_select "button", text: /Wrong repository data/, count: 0
  end

  private
    def assert_no_shared_data
      assert_select ".list-row", text: /Repository-only sample/, count: 0
      assert_select "h1", text: /Safe to merge without review/, count: 0
      assert_not_includes response.body, "app/sample.rb"
    end

    def assert_no_private_history(legacy)
      assert_not_includes response.body, legacy.pr_title
      assert_not_includes response.body, "My migrated reason"
      assert_not_includes response.body, "Private reason"
    end
end
