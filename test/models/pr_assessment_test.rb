require "test_helper"

class PrAssessmentTest < ActiveSupport::TestCase
  test "only accepts Jev's three options" do
    assessment = users(:one).pr_assessments.new(repo_full_name: "acme/web", pr_number: 1, pr_title: "x", pr_url: "https://github.com/acme/web/pull/1", choice: "maybe")

    assert_not assessment.valid?
    assert assessment.errors.of_kind?(:choice, :inclusion)
  end

  test "ranked probabilities follow the tag order and default missing options to zero" do
    assessment = PrAssessment.new(choice: "no", probabilities: { "no" => 0.9, "yes" => 0.1 })

    assert_equal [ [ "yes", 0.1 ], [ "llm_enough", 0.0 ], [ "no", 0.9 ] ], assessment.ranked_probabilities.map { |key, _, p| [ key, p ] }
  end

  test "only links to github.com" do
    assessment = users(:one).pr_assessments.new(repo_full_name: "acme/web", pr_number: 1, pr_title: "x", pr_url: "javascript:alert(1)", choice: "no")

    assert_not assessment.valid?
    assert assessment.errors.of_kind?(:pr_url, :invalid)
  end

  test "search matches every term against title, repository or PR number" do
    user = users(:one)
    a = user.pr_assessments.create!(repo_full_name: "acme/web", pr_number: 42, pr_title: "Fix 100% CPU", pr_url: "https://github.com/acme/web/pull/42", choice: "no")
    user.pr_assessments.create!(repo_full_name: "acme/api", pr_number: 7, pr_title: "Fix login", pr_url: "https://github.com/acme/api/pull/7", choice: "no")

    assert_equal [ a ], user.pr_assessments.search("fix web").to_a
    assert_equal [ a ], user.pr_assessments.search("#42").to_a
    assert_equal [ a ], user.pr_assessments.search("100%").to_a
    assert_empty user.pr_assessments.search("Fix_login").to_a # "_" is literal, not "any character"
    assert_equal 2, user.pr_assessments.search("").count
  end

  test "a verdict is current for the commit it was given on (older verdicts without a SHA count as current)" do
    pr = Data.define(:head_sha).new(head_sha: "abc")

    assert PrAssessment.new(head_sha: "abc").current_for?(pr)
    assert_not PrAssessment.new(head_sha: "old").current_for?(pr)
    assert PrAssessment.new(head_sha: nil).current_for?(pr)
  end

  test "files_by_verdict puts human review files first, then LLM, then no review, then files without a verdict" do
    files = [ { "filename" => "docs.md", "choice" => "no" }, { "filename" => "logo.png", "skipped" => "no_patch" },
              { "filename" => "auth.rb", "choice" => "yes" }, { "filename" => "a_test.rb", "choice" => "llm_enough" },
              { "filename" => "b_test.rb", "choice" => "llm_enough" }, { "filename" => "pay.rb", "choice" => "yes" } ]

    assert_equal %w[auth.rb pay.rb a_test.rb b_test.rb docs.md logo.png],
                 PrAssessment.new(files: files).files_by_verdict.map { |f| f["filename"] }
  end

  test "agreeing records Jev's own verdict and drops any reason" do
    assessment = create_assessment(choice: "no")

    assessment.record_feedback!(choice: "no", reason: "Looks fine")

    assert assessment.agreed?
    assert_nil assessment.feedback_reason
    assert assessment.feedback_at
  end

  test "disagreeing records the verdict it should have been and an optional reason" do
    assessment = create_assessment(choice: "no")

    assessment.record_feedback!(choice: "yes", reason: "  It touches the payments webhook.  ")

    assert assessment.disagreed?
    assert_equal [ "yes", "It touches the payments webhook." ], [ assessment.feedback_choice, assessment.feedback_reason ]
  end

  test "feedback only accepts Jev's three options and a short reason" do
    assessment = create_assessment(choice: "no")

    assert_raises(ActiveRecord::RecordInvalid) { assessment.record_feedback!(choice: "maybe") }
    assert_raises(ActiveRecord::RecordInvalid) { assessment.record_feedback!(choice: "yes", reason: "x" * 1_001) }
  end

  test "clearing feedback removes the vote" do
    assessment = create_assessment(choice: "no")
    assessment.record_feedback!(choice: "yes", reason: "Risky")

    assessment.clear_feedback!

    assert_not assessment.reload.feedback?
    assert_equal [ nil, nil, nil ], [ assessment.feedback_choice, assessment.feedback_reason, assessment.feedback_at ]
  end

  test "the feedback summary counts agreement and which way Jev was wrong" do
    create_assessment(choice: "no").record_feedback!(choice: "no")
    create_assessment(choice: "llm_enough").record_feedback!(choice: "llm_enough")
    create_assessment(choice: "no").record_feedback!(choice: "yes")
    create_assessment(choice: "llm_enough").record_feedback!(choice: "yes")
    create_assessment(choice: "yes").record_feedback!(choice: "no")
    create_assessment(choice: "yes")

    summary = users(:one).pr_assessments.feedback_summary

    assert_equal [ 5, 2, 2, 1 ], [ summary.rated, summary.agreed, summary.needed_more, summary.needed_less ]
  end

  private
    def create_assessment(choice:)
      @number = @number.to_i + 1
      users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: @number, pr_title: "PR #{@number}",
                                         pr_url: "https://github.com/acme/web/pull/#{@number}", choice: choice)
    end
end
