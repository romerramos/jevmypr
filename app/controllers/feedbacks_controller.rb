# Your private vote on a repository verdict: agree, or say what it should have been and why.
class FeedbacksController < ApplicationController
  include GithubErrors
  before_action :set_assessment

  def edit
  end

  def update
    choice = params.dig(:feedback, :choice).presence_in(PrAssessment::VERDICTS.keys)
    unless choice
      @error = "Pick what the verdict should have been."
      return render :edit, status: :unprocessable_entity
    end

    @feedback.record!(choice: choice, reason: params.dig(:feedback, :reason).to_s.first(Feedback::MAX_REASON))
    redirect_to assessment_path(@assessment), status: :see_other
  end

  def destroy
    @feedback.destroy! if @feedback.persisted?
    redirect_to assessment_path(@assessment), status: :see_other
  end

  private
    def set_assessment
      @assessment = PrAssessment.find(params[:assessment_id]).verify_access!(user: Current.user, github: github)
      @feedback = Current.user.feedbacks.find_or_initialize_by(pr_assessment: @assessment)
    end

    def default_frame = "feedback"
end
