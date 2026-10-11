class Feedback < ApplicationRecord
  MAX_REASON = 1_000
  Summary = Data.define(:rated, :agreed, :needed_more, :needed_less)

  belongs_to :user
  belongs_to :pr_assessment

  validates :choice, inclusion: { in: PrAssessment::VERDICTS.keys }
  validates :reason, length: { maximum: MAX_REASON }
  validates :pr_assessment_id, uniqueness: { scope: :user_id }

  def record!(choice:, reason: nil)
    update!(choice: choice, reason: (reason.to_s.strip.presence unless choice == pr_assessment.choice), voted_at: Time.current)
  end

  def agreed? = choice.present? && choice == pr_assessment.choice
  def disagreed? = choice.present? && !agreed?

  def self.summary
    votes = joins(:pr_assessment).pluck("pr_assessments.choice", :choice)
    rank = PrAssessment::VERDICTS.keys.reverse
    Summary.new(
      rated: votes.size,
      agreed: votes.count { |choice, vote| choice == vote },
      needed_more: votes.count { |choice, vote| rank.index(vote) > rank.index(choice) },
      needed_less: votes.count { |choice, vote| rank.index(vote) < rank.index(choice) }
    )
  end
end
