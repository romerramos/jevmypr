class AssessmentsController < ApplicationController
  rate_limit to: 20, within: 1.minute, only: :create, with: -> { redirect_back_or_to root_path, alert: "That's a lot of PRs at once. Wait a minute and try again." }

  def create
    repo = params.require(:repo)
    result = PrReviewDecider.new(github: github).decide(repo, params.require(:number))
    assessment = PrAssessment.from_result(user: Current.user, repo_full_name: repo, result: result)
    assessment.save!

    redirect_to assessment_path(assessment)
  rescue Github::Client::Unauthorized => error
    terminate_session
    redirect_to new_session_path, alert: error.message
  rescue Github::Client::Error, Jev::Client::Error => error
    redirect_to root_path(repo: params[:repo]), alert: error.message
  end

  def show
    @assessment = Current.user.pr_assessments.find(params[:id])
  end
end
