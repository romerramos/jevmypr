require "test_helper"

class DevelopmentPreviewTest < ActiveSupport::TestCase
  test "is off outside development" do
    assert_not DevelopmentPreview.enabled?
  end

  test "sample verdicts cover the three tags and spend no tokens" do
    decider = PrReviewDecider.new(github: Github::PreviewClient.new, jev: Jev::PreviewClient.new)
    results = [ [ "acme/web", 42 ], [ "acme/billing", 18 ], [ "acme/web", 7 ] ].map { |repo, number| decider.decide(repo, number) }

    assert_equal %w[ yes llm_enough no ], results.map { |result| result.decision.choice }
    assert results.all? { |result| result.usage["input_tokens"].zero? }
  end

  test "a sample pull request becomes a saved verdict with file verdicts, without calling GitHub or Jev" do
    result = PrReviewDecider.new(github: Github::PreviewClient.new, jev: Jev::PreviewClient.new).decide("acme/web", 42)

    repository = Repository.from_github!(Github::PreviewClient.new.repository("acme/web"))
    assessment = PrAssessment.from_result(user: DevelopmentPreview.user, repository: repository, result: result)
    assert assessment.valid?
    assert_equal(-101, repository.github_id)
    assert_not Repository.new(github_id: 0, full_name: "acme/zero").valid?
    assert_equal "yes", assessment.choice
    assert_equal 0, assessment.input_tokens
    assert_equal %w[ yes llm_enough yes ], result.files.map { |verdict| verdict.decision.choice }
    assert_not_requested :post, Jev::Client::URL
  end

  test "a sample file with no text diff is skipped like a real one" do
    result = PrReviewDecider.new(github: Github::PreviewClient.new, jev: Jev::PreviewClient.new).decide("acme/web", 7)

    assert_equal [ "no", :no_patch ], result.files.map { |verdict| verdict.decision&.choice || verdict.skipped }
  end
end
