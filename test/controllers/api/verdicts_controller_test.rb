require "test_helper"

class Api::VerdictsControllerTest < ActionDispatch::IntegrationTest
  DIFF = { title: "Fix login redirect", repository: "acme/web",
           files: [ { filename: "app/controllers/sessions_controller.rb", status: "modified", patch: "@@ -1 +1 @@\n-old\n+new" } ] }.freeze

  setup { Api::VerdictsController.cache_store.clear }

  def post_diff(body = DIFF, **options)
    post api_verdicts_path, params: body.is_a?(String) ? body : body.to_json, headers: { "Content-Type" => "application/json" }, **options
  end

  test "returns a compact verdict for a diff with no session, cookie or API key" do
    stub_jev(choice: "yes", confidence: 0.72)

    post_diff

    assert_response :success
    assert_equal({ "verdict" => "human", "confidence" => 0.72, "diff_truncated" => false, "url" => nil,
                   "files" => [ { "filename" => "app/controllers/sessions_controller.rb", "verdict" => "human" } ] }, response.parsed_body)
    assert_nil response.cookies["session_id"]
    assert_requested :post, Jev::Client::URL, times: 1
    assert_not_requested :any, /api\.github\.com/

    request = JevRequest.order(:id).last
    assert_equal [ nil, nil, nil, nil, "succeeded", 10, 2 ],
                 request.values_at(:user_id, :repository_id, :pr_number, :head_sha, :state, :input_tokens, :output_tokens)
    assert_equal [ "api", DiffPayload.new(DIFF).sha256, JevRequest.ip_digest("127.0.0.1") ], request.values_at(:source, :diff_sha256, :ip_digest)

    # Saved without an owner or a pull request, only its title, counts, file metadata and verdicts.
    saved = PrAssessment.find_by!(jev_request: request)
    assert_equal [ "api", nil, nil, nil, nil, nil, "Fix login redirect", "yes" ],
                 saved.values_at(:source, :user_id, :repository_id, :repo_full_name, :pr_number, :pr_url, :pr_title, :choice)
    assert_equal request.diff_sha256, saved.diff_sha256
    assert_match(/\A[1-9A-HJ-NP-Za-km-z]{24}\z/, saved.token)
    assert_in_delta PrAssessment::API_LIFETIME.from_now, saved.expires_at, 5
    assert_not saved.files.sole.key?("patch")
  end

  test "the same diff sent again reuses its verdict without calling Jev" do
    stub_jev(choice: "no")

    post_diff
    travel JevAllowance::LIMITS.api_calls_window + 1.second # past the rate limit
    assert_no_difference [ -> { JevRequest.count }, -> { PrAssessment.count } ] do
      post_diff(DIFF.merge(title: "Another title"))
    end

    assert_response :success
    assert_equal "none", response.parsed_body["verdict"]
    assert_requested :post, Jev::Client::URL, times: 1
  end

  test "an expired verdict isn't reused" do
    stub_jev(choice: "no")

    post_diff
    travel PrAssessment::API_LIFETIME + 1.hour
    post_diff

    assert_response :success
    assert_requested :post, Jev::Client::URL, times: 2
    assert_equal 2, PrAssessment.api.count
  end

  test "files without a verdict say why" do
    diff = DIFF.merge(files: [ { filename: "logo.png", status: "added" }, *DIFF[:files] ])
    stub_request(:post, Jev::Client::URL).to_return(json_response({
      model: "jev-1.13.0", usage: {},
      answers: { PrReviewDecider::QUESTION_ID => { choice: "llm_enough", probabilities: {}, confidence: 0.6 },
                 "file_1" => { choice: "no", probabilities: {}, confidence: 0.6 } }
    }))

    post_diff(diff)

    assert_equal [ { "filename" => "logo.png", "verdict" => nil, "skipped" => "no_patch" },
                   { "filename" => "app/controllers/sessions_controller.rb", "verdict" => "none" } ], response.parsed_body["files"]
  end

  test "an invalid diff is refused before Jev is asked" do
    post_diff(DIFF.merge(files: [ { filename: "", status: "deleted" } ]))

    assert_response :unprocessable_content
    assert_equal "invalid_diff", response.parsed_body["error"]
    assert_includes response.parsed_body["details"], "files[0].status must be one of #{DiffPayload::STATUSES.to_sentence(last_word_connector: ' or ')}"
    assert_not_requested :post, Jev::Client::URL
  end

  test "a body that isn't JSON is a clear error" do
    post_diff(+"{not json")

    assert_response :bad_request
    assert_equal "invalid_json", response.parsed_body["error"]
  end

  test "a diff too big for Jev is a clear error" do
    stub_request(:post, Jev::Client::URL).to_return(json_response({ error_type: "max_tokens_exceeded" }, status: 400))

    post_diff

    assert_response :content_too_large
    assert_equal "too_large", response.parsed_body["error"]
    assert_equal "oversized", JevRequest.order(:id).last.state
  end

  test "a diff already being assessed is a conflict with Retry-After" do
    JevRequest.create!(source: "api", diff_sha256: DiffPayload.new(DIFF).sha256)

    post_diff

    assert_response :conflict
    assert_equal "in_progress", response.parsed_body["error"]
    assert_equal "120", response.headers["Retry-After"]
    assert_not_requested :post, Jev::Client::URL
  end

  test "pauses with Retry-After once the month's budget is spent" do
    JevRequest.create!(sent_at: Time.current, input_tokens: 1_000_000_000, state: "succeeded")

    post_diff

    assert_response :service_unavailable
    assert_equal "budget_paused", response.parsed_body["error"]
    assert_match "budget for this month is spent", response.parsed_body["message"]
    assert_operator response.headers["Retry-After"].to_i, :>, 0
    assert_not_requested :post, Jev::Client::URL
  end

  test "the API pauses once it has spent its share of the budget" do
    budget = JevAllowance::LIMITS.monthly_budget_usd * JevAllowance::LIMITS.api_budget_share
    JevRequest.create!(source: "api", sent_at: Time.current, state: "succeeded",
                       input_tokens: (budget / JevAllowance::LIMITS.usd_per_million_input_tokens * 1_000_000).ceil)

    post_diff

    assert_response :service_unavailable
    assert_equal "budget_paused", response.parsed_body["error"]
    assert_match "API's share", response.parsed_body["message"]
    assert_not_requested :post, Jev::Client::URL
  end

  test "an IP address over its daily cap gets 429 with Retry-After" do
    created_at = 2.hours.ago
    JevAllowance::LIMITS.api_daily_verdicts_per_ip.times do
      JevRequest.create!(source: "api", ip_digest: JevRequest.ip_digest("127.0.0.1"), sent_at: created_at, created_at: created_at, state: "succeeded")
    end

    post_diff

    assert_response :too_many_requests
    assert_equal "not_allowed", response.parsed_body["error"]
    assert_match "This IP address has used all", response.parsed_body["message"]
    assert_in_delta 22.hours, response.headers["Retry-After"].to_i, 5
    assert_not_requested :post, Jev::Client::URL
  end

  test "an oversized body is refused before it is read" do
    post_diff(+"x" * (Api::VerdictsController::MAX_BODY_BYTES + 1))

    assert_response :content_too_large
    assert_equal "body_too_large", response.parsed_body["error"]
    assert_not_requested :post, Jev::Client::URL
  end

  test "too many calls from one IP get 429" do
    stub_jev(choice: "no")

    JevAllowance::LIMITS.api_calls_per_ip.times { post_diff }
    assert_response :success
    post_diff

    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body["error"]
    assert_equal "120", response.headers["Retry-After"]
  end
end
