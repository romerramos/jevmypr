require "test_helper"

class FeedbackTest < ActiveSupport::TestCase
  test "agreeing drops the reason and disagreeing keeps a trimmed private reason" do
    feedback = users(:one).feedbacks.new(pr_assessment: assessment("no"))
    feedback.record!(choice: "yes", reason: "  It changes payments.  ")

    assert feedback.disagreed?
    assert_equal [ "yes", "It changes payments." ], feedback.values_at(:choice, :reason)
    assert feedback.voted_at

    feedback.record!(choice: "no", reason: "Not kept when agreeing")
    assert feedback.agreed?
    assert_nil feedback.reason
  end

  test "only accepts the three options and reasons of at most 1000 characters" do
    feedback = users(:one).feedbacks.new(pr_assessment: assessment("no"))

    assert_raises(ActiveRecord::RecordInvalid) { feedback.record!(choice: "maybe") }
    feedback.record!(choice: "yes", reason: "x" * 1_000)
    assert_equal 1_000, feedback.reason.length
    assert_raises(ActiveRecord::RecordInvalid) { feedback.record!(choice: "yes", reason: "x" * 1_001) }
  end

  test "one personal vote per assessment, with separate votes for teammates" do
    snapshot = assessment("no")
    users(:one).feedbacks.create!(pr_assessment: snapshot, choice: "yes", reason: "Mine", voted_at: Time.current)
    other = users(:two).feedbacks.create!(pr_assessment: snapshot, choice: "llm_enough", reason: "Theirs", voted_at: Time.current)

    duplicate = users(:one).feedbacks.new(pr_assessment: snapshot, choice: "no", voted_at: Time.current)
    assert_not duplicate.valid?
    assert_equal "Theirs", other.reload.reason
  end

  test "the personal summary counts agreement and both directions of disagreement" do
    [ [ "no", "no" ], [ "llm_enough", "llm_enough" ], [ "no", "yes" ], [ "llm_enough", "yes" ], [ "yes", "no" ] ].each do |verdict, vote|
      users(:one).feedbacks.new(pr_assessment: assessment(verdict)).record!(choice: vote)
    end
    users(:two).feedbacks.new(pr_assessment: assessment("yes")).record!(choice: "yes")

    summary = users(:one).feedbacks.summary
    assert_equal [ 5, 2, 2, 1 ], [ summary.rated, summary.agreed, summary.needed_more, summary.needed_less ]
  end

  private
    def assessment(choice)
      users(:one).pr_assessments.create!(repository: repositories(:web), head_sha: "abc", repo_full_name: "acme/web",
        pr_number: 7, pr_title: "PR", pr_url: "https://github.com/acme/web/pull/7", choice: choice)
    end
end
