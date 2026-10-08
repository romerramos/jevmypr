require "test_helper"

class SharedAssessmentsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
    stub_github_repositories("acme/web")
    stub_github_pull_request
    stub_jev(choice: "yes")
  end

  test "teammate reuse is free before age, weekly, monthly and new-analysis throttle checks" do
    ask
    saved = PrAssessment.last
    users(:two).update!(github_created_at: 1.day.ago)
    30.times { users(:two).jev_requests.create!(state: "succeeded", sent_at: 1.hour.ago, created_at: 1.hour.ago) }
    JevRequest.create!(state: "succeeded", sent_at: Time.current, input_tokens: 500_000_000)
    sign_in_as users(:two)
    assert_not JevAllowance.new(users(:two)).allowed?

    assert_no_difference [ -> { PrAssessment.count }, -> { JevRequest.count } ] do
      7.times do
        ask
        assert_redirected_to assessment_path(saved)
      end
    end
    assert_requested :post, Jev::Client::URL, times: 1
    assert_equal [ 1, 30 ], [ JevAllowance.new(users(:one)).weekly_used, JevAllowance.new(users(:two)).weekly_used ]
    follow_redirect!
    assert_select "[aria-label='Verdict privacy']", text: /Shared repository verdict/
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "meta[name=turbo-cache-control][content=no-cache]"
    assert_select "body[data-turbo-prefetch=false]"
  end

  test "a new head calls Jev once and charges only the new requester" do
    ask
    first = PrAssessment.last
    sign_in_as users(:two)
    stub_github_pull_request(head_sha: "different-head")

    assert_difference -> { PrAssessment.count }, 1 do
      ask
      ask
    end
    current = PrAssessment.last
    assert_equal "different-head", current.head_sha
    assert_equal "sha-7", first.reload.head_sha
    assert_equal users(:two), current.user
    assert_equal [ 1, 1 ], [ JevAllowance.new(users(:one)).weekly_used, JevAllowance.new(users(:two)).weekly_used ]
    assert_requested :post, Jev::Client::URL, times: 2
  end

  test "explicit reanalysis of the same head creates another shared snapshot and uses the requester's quota" do
    ask
    first = PrAssessment.last
    users(:one).feedbacks.new(pr_assessment: first).record!(choice: "no", reason: "Original private vote")
    sign_in_as users(:two)

    assert_difference -> { PrAssessment.count }, 1 do
      ask(fresh: "1")
    end
    fresh = PrAssessment.last
    assert_not_equal first.id, fresh.id
    assert_equal first.head_sha, fresh.head_sha
    assert fresh.jev_request.fresh?
    assert_equal users(:two), fresh.user
    assert_equal "Original private vote", users(:one).feedbacks.find_by!(pr_assessment: first).reason
    assert_equal [ 1, 1 ], [ JevAllowance.new(users(:one)).weekly_used, JevAllowance.new(users(:two)).weekly_used ]
    assert_requested :post, Jev::Client::URL, times: 2
  end

  test "a shared verdict is reusable even after the new-analysis minute throttle is exhausted" do
    5.times { ask(fresh: "1") }
    saved = PrAssessment.last
    ask(fresh: "1")
    assert_match "a lot of pull requests", flash[:alert]

    assert_no_difference -> { JevRequest.count } do
      ask
    end
    assert_redirected_to assessment_path(saved)
    assert_requested :post, Jev::Client::URL, times: 5
  end

  test "private legacy snapshots at the same head are not reused or rebound" do
    legacy = users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 7, pr_title: "Old private title",
      pr_url: "https://github.com/acme/web/pull/7", choice: "no", head_sha: "sha-7")

    assert_difference -> { PrAssessment.count }, 1 do
      ask
    end
    assert_nil legacy.reload.repository_id
    assert_equal repositories(:web), PrAssessment.last.repository
    assert_requested :post, Jev::Client::URL, times: 1
  end

  test "a pending teammate request is coalesced before allowance checks without charging the viewer" do
    JevRequest.create!(repository: repositories(:web), user: users(:one), pr_number: 7, head_sha: "sha-7")
    users(:two).update!(github_created_at: 1.day.ago)
    sign_in_as users(:two)

    assert_no_difference -> { JevRequest.count } do
      ask
    end
    assert_match "already being prepared", flash[:alert]
    assert_equal 0, JevAllowance.new(users(:two)).weekly_used
    assert_not_requested :post, Jev::Client::URL
  end

  test "an expired abandoned reservation permits one new ordinary analysis" do
    abandoned = JevRequest.create!(repository: repositories(:web), user: users(:one), pr_number: 7,
      head_sha: "sha-7", created_at: 31.minutes.ago)
    sign_in_as users(:two)

    assert_difference -> { JevRequest.count }, 1 do
      ask
      ask
    end
    assert_equal [ "failed", nil ], abandoned.reload.values_at(:state, :sent_at)
    assert_equal "succeeded", JevRequest.last.state
    assert_equal [ 0, 1 ], [ JevAllowance.new(users(:one)).weekly_used, JevAllowance.new(users(:two)).weekly_used ]
    assert_requested :post, Jev::Client::URL, times: 1
  end

  test "an unchanged oversized result stops teammates from retrying, and a new head can succeed" do
    stub_request(:post, Jev::Client::URL).to_return(json_response({ error_type: "max_tokens_exceeded" }, status: 400))
    ask
    sign_in_as users(:two)

    assert_no_difference -> { JevRequest.count } do
      ask
    end
    assert_match "too big for Jev", flash[:alert]
    assert_equal 0, JevAllowance.new(users(:two)).weekly_used
    assert_requested :post, Jev::Client::URL, times: 1

    stub_github_pull_request(head_sha: "smaller-head")
    stub_jev(choice: "no")
    ask
    assert_equal "smaller-head", PrAssessment.last.head_sha
    assert_equal [ 1, 1 ], [ JevAllowance.new(users(:one)).weekly_used, JevAllowance.new(users(:two)).weekly_used ]
    assert_requested :post, Jev::Client::URL, times: 2
  end

  test "GitHub failure before Jev releases the reservation without charging quota" do
    stub_request(:get, "#{ApiStubs::GITHUB}/repositories/101/pulls/7/files").with(query: hash_including({}))
      .to_return(json_response({}, status: 500))
    ask

    assert_equal [ "failed", nil ], JevRequest.last.values_at(:state, :sent_at)
    assert_equal 0, JevAllowance.new(users(:one)).weekly_used
    assert_not_requested :post, Jev::Client::URL

    stub_github_pull_request
    ask
    assert_equal 1, JevAllowance.new(users(:one)).weekly_used
    assert_equal "succeeded", JevRequest.last.state
  end

  test "a head change while loading files does not analyze or charge the wrong commit" do
    stub_request(:get, "#{ApiStubs::GITHUB}/repositories/101/pulls/7").to_return(
      json_response(pull_request_json), json_response(pull_request_json(head_sha: "moved-head")))
    ask

    assert_match "changed while its diff was loading", flash[:alert]
    assert_equal 0, PrAssessment.count
    assert_equal 0, JevAllowance.new(users(:one)).weekly_used
    assert_equal "failed", JevRequest.last.state
    assert_not_requested :post, Jev::Client::URL
  end

  test "paid usage survives an invalid Jev answer even though no snapshot can be saved" do
    stub_request(:post, Jev::Client::URL).to_return(json_response({ model: "jev", answers: {}, usage: { input_tokens: 1234, output_tokens: 17 } }))
    ask

    assert_equal 0, PrAssessment.count
    assert_equal [ "failed", 1234, 17 ], JevRequest.last.values_at(:state, :input_tokens, :output_tokens)
    assert_equal 1, JevAllowance.new(users(:one)).weekly_used
    assert_in_delta 0.000052542, JevAllowance.new(users(:one)).monthly_spend_usd, 1e-12
  end

  private
    def ask(**params)
      post repository_pull_request_assessments_path(owner: "acme", repo: "web", pull_request_number: 7), params: params
    end
end
