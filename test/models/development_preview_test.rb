require "test_helper"

class DevelopmentPreviewTest < ActiveSupport::TestCase
  test "is off unless development asks for it" do
    assert_not DevelopmentPreview.enabled?
  end

  test "sample verdicts cover the three tags and spend no tokens" do
    responses = [ 42, 18, 7 ].map { |number| DevelopmentPreview.jev_response(number) }

    assert_equal %w[ yes llm_enough no ], responses.map { |response| response.answers.dig("needs_human_review", "choice") }
    assert responses.all? { |response| response.usage["input_tokens"].zero? }
  end

  test "a sample pull request becomes a saved verdict without calling GitHub or Jev" do
    result = PrReviewDecider.new(github: Github::PreviewClient.new, jev: Jev::PreviewClient.new).decide("acme/web", 42)

    assessment = PrAssessment.from_result(user: users(:one), repo_full_name: "acme/web", result: result)
    assert assessment.valid?
    assert_equal "yes", assessment.choice
    assert_equal 0, assessment.input_tokens
    assert_not_requested :post, Jev::Client::URL
  end
end
