require "test_helper"

class PrReviewDeciderTest < ActiveSupport::TestCase
  class FakeGithub
    attr_reader :files

    def initialize(files: [ self.class.file("README.md", "+typo fix") ])
      @files = files
    end

    def self.file(filename, patch, status: "modified")
      Github::Client::FileChange.new(filename: filename, previous_filename: nil, status: status, additions: 1, deletions: 1, patch: patch)
    end

    def pull_request(full_name, number)
      Github::Client::PullRequest.new(number: number, title: "Fix README typo", body: "Small fix", html_url: "https://github.com/#{full_name}/pull/#{number}",
                                      draft: false, author_login: "ana", author_avatar_url: nil, base_ref: "main", head_ref: "typo", head_sha: "abc123",
                                      additions: 1, deletions: 1, changed_files: 1, updated_at: Time.current)
    end

    def pull_request_files(*) = files
  end

  class FakeJev
    attr_reader :calls

    # Answers every question with `answer`, unless `answers` names one by id (nil leaves it unanswered).
    def initialize(answer, answers: {})
      @answer = answer
      @answers = answers
      @calls = []
    end

    def ask(**kwargs)
      @calls << kwargs
      answers = kwargs[:questions].keys.to_h { |id| [ id, @answers.fetch(id, @answer) ] }.compact
      Jev::Client::Response.new(model: "jev-1.13.0", answers: answers, usage: {})
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
    assert_equal({ filename: "README.md", status: "modified", additions: 1, deletions: 1, patch: "+typo fix" }, call[:state][:files].sole)
  end

  test "asks about every file in the same request, pointing each question at its file" do
    files = [ FakeGithub.file("app/auth.rb", "+token check"), FakeGithub.file("logo.png", nil), FakeGithub.file("README.md", "+typo") ]
    jev = FakeJev.new({ "choice" => "llm_enough", "probabilities" => {}, "confidence" => 0.6 },
                      answers: { "file_0" => { "choice" => "yes", "probabilities" => { "yes" => 0.9 }, "confidence" => 0.8 } })

    result = PrReviewDecider.new(github: FakeGithub.new(files: files), jev: jev).decide("acme/web", 7)

    call = jev.calls.sole
    assert_equal [ PrReviewDecider::QUESTION_ID, "file_0", "file_2" ], call[:questions].keys
    assert_equal "Does the change to `files[2]` need a review from a human?", call[:questions]["file_2"][:instructions]
    assert_equal call[:questions][PrReviewDecider::QUESTION_ID][:criteria], call[:questions]["file_2"][:criteria]
    assert_equal "binary or no text diff", call[:state][:files][1][:patch_omitted]

    assert_equal [ "yes", nil, "llm_enough" ], result.files.map { |f| f.decision&.choice }
    assert_equal [ nil, :no_patch, nil ], result.files.map(&:skipped)
    assert_equal 0.9, result.files.first.decision.probabilities["yes"]
  end

  test "a missing file answer leaves only that file without a verdict" do
    files = [ FakeGithub.file("a.rb", "+a"), FakeGithub.file("b.rb", "+b") ]
    jev = FakeJev.new({ "choice" => "no", "probabilities" => {}, "confidence" => 0.6 }, answers: { "file_1" => { "choice" => "maybe" } })

    result = PrReviewDecider.new(github: FakeGithub.new(files: files), jev: jev).decide("acme/web", 7)

    assert_equal "no", result.decision.choice
    assert_equal [ nil, :no_answer ], result.files.map(&:skipped)
  end

  test "leaves out whole patches past the size budget instead of cutting them" do
    half = PrReviewDecider::MAX_DIFF_BYTES / 2
    files = [ FakeGithub.file("a.rb", "+" * half), FakeGithub.file("big.rb", "+" * (half + 1)), FakeGithub.file("c.rb", "+small") ]
    jev = FakeJev.new({ "choice" => "yes", "probabilities" => {}, "confidence" => 0.5 })

    result = PrReviewDecider.new(github: FakeGithub.new(files: files), jev: jev).decide("acme/web", 7)

    assert result.diff_truncated
    state_files = jev.calls.sole[:state][:files]
    assert_equal [ half, nil, 6 ], state_files.map { |f| f[:patch]&.bytesize }
    assert_equal "left out to fit the size limit", state_files[1][:patch_omitted]
    assert_equal [ nil, :too_large, nil ], result.files.map(&:skipped)
  end

  test "asks about at most MAX_FILE_QUESTIONS files" do
    files = (PrReviewDecider::MAX_FILE_QUESTIONS + 2).times.map { |i| FakeGithub.file("f#{i}.rb", "+#{i}") }
    jev = FakeJev.new({ "choice" => "no", "probabilities" => {}, "confidence" => 0.5 })

    result = PrReviewDecider.new(github: FakeGithub.new(files: files), jev: jev).decide("acme/web", 7)

    assert_equal PrReviewDecider::MAX_FILE_QUESTIONS + 1, jev.calls.sole[:questions].size
    assert_equal [ :too_many, :too_many ], result.files.last(2).map(&:skipped)
    assert_not result.diff_truncated
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
