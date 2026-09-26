require "test_helper"

class PrReviewDeciderTest < ActiveSupport::TestCase
  class FakeGithub
    attr_reader :diff

    def initialize(diff: "diff --git a/README.md b/README.md\n+typo fix\n")
      @diff = diff
    end

    def pull_request(full_name, number)
      Github::Client::PullRequest.new(number: number, title: "Fix README typo", body: "Small fix", html_url: "https://github.com/#{full_name}/pull/#{number}",
                                      draft: false, author_login: "ana", author_avatar_url: nil, base_ref: "main", head_ref: "typo", head_sha: "abc123",
                                      additions: 1, deletions: 1, changed_files: 1, updated_at: Time.current)
    end

    def pull_request_files(*)
      [ Github::Client::FileChange.new(filename: "README.md", status: "modified", additions: 1, deletions: 1) ]
    end

    def pull_request_diff(*) = diff
  end

  class FakeJev
    attr_reader :calls

    def initialize(answer)
      @answer = answer
      @calls = []
    end

    def ask(**kwargs)
      @calls << kwargs
      Jev::Client::Response.new(model: "jev-1.13.0", answers: { PrReviewDecider::QUESTION_ID => @answer }, usage: {})
    end
  end

  test "asks Jev the review question with the PR as state and returns its decision" do
    jev = FakeJev.new({ "type" => "choice", "choice" => "no", "probabilities" => { "yes" => 0.05, "llm_enough" => 0.15, "no" => 0.8 }, "confidence" => 0.74 })

    result = PrReviewDecider.new(github: FakeGithub.new, jev: jev).decide("acme/web", 7)

    assert_equal "no", result.decision.choice
    assert_equal 0.8, result.decision.probabilities["no"]
    assert_equal 0.74, result.decision.confidence
    assert_equal "jev-1.13.0", result.decision.model
    assert_equal "Fix README typo", result.pull_request.title
    assert_not result.diff_truncated

    call = jev.calls.sole
    question = call[:questions][PrReviewDecider::QUESTION_ID]
    assert_equal "choice", question[:type]
    assert_equal "Does this PR need a review from a human?", question[:instructions]
    assert_equal %w[yes llm_enough no], question[:criteria].keys
    assert_equal "acme/web", call[:state][:repository]
    assert_equal [ "modified README.md (+1 -1)" ], call[:state][:files]
    assert_match "typo fix", call[:state][:diff]
  end

  test "truncates very large diffs" do
    big_diff = "+" * (PrReviewDecider::MAX_DIFF_BYTES + 500)
    jev = FakeJev.new({ "choice" => "yes", "probabilities" => {}, "confidence" => 0.5 })

    result = PrReviewDecider.new(github: FakeGithub.new(diff: big_diff), jev: jev).decide("acme/web", 7)

    assert result.diff_truncated
    assert_equal PrReviewDecider::MAX_DIFF_BYTES, jev.calls.sole[:state][:diff].bytesize
    assert jev.calls.sole[:state][:diff_truncated]
  end

  test "rejects answers outside the three options" do
    jev = FakeJev.new({ "choice" => "maybe", "probabilities" => {}, "confidence" => 0.5 })

    assert_raises(Jev::Client::Error) { PrReviewDecider.new(github: FakeGithub.new, jev: jev).decide("acme/web", 7) }
  end

  test "a pull request too big for Jev raises TooLarge with the pull request" do
    jev = Object.new
    def jev.ask(**) = raise(Jev::Client::TooLarge, "too big")

    error = assert_raises(PrReviewDecider::TooLarge) { PrReviewDecider.new(github: FakeGithub.new, jev: jev).decide("acme/web", 7) }
    assert_equal "abc123", error.pull_request.head_sha
  end
end
