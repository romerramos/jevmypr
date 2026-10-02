# Your vote on one of your verdicts: agree, or say what it should have been and why.
class FeedbacksController < ApplicationController
  before_action :set_assessment

  def edit
  end

  def update
    choice = params.dig(:feedback, :choice).presence_in(PrAssessment::VERDICTS.keys)
    unless choice
      @error = "Pick what the verdict should have been."
      return render :edit, status: :unprocessable_entity
    end

    @assessment.record_feedback!(choice: choice, reason: params.dig(:feedback, :reason).to_s.first(PrAssessment::MAX_FEEDBACK_REASON))
    redirect_to assessment_path(@assessment), status: :see_other
  end

  def destroy
    @assessment.clear_feedback!
    redirect_to assessment_path(@assessment), status: :see_other
  end

  private
    def set_assessment
      @assessment = Current.user.pr_assessments.find(params[:assessment_id])
    end
end
