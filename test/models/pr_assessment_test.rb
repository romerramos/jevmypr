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
end
