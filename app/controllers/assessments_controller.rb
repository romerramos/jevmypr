class AssessmentsController < ApplicationController
  rate_limit to: 20, within: 1.minute, only: :create, with: -> { redirect_back_or_to repositories_path, alert: "That's a lot of PRs at once. Wait a minute and try again." }

  def index
    @assessments = Current.user.pr_assessments.recent.limit(100)
  end

  def show
    @assessment = Current.user.pr_assessments.find(params[:id])
  end

  def create
    repo = "#{params[:owner]}/#{params[:repo]}"
    result = PrReviewDecider.new(github: github).decide(repo, params[:pull_request_number])
    assessment = PrAssessment.from_result(user: Current.user, repo_full_name: repo, result: result)
    assessment.save!

    redirect_to assessment_path(assessment)
  rescue Github::Client::Unauthorized => error
    terminate_session
    redirect_to new_session_path, alert: error.message
  rescue Github::Client::Error, Jev::Client::Error => error
    redirect_to repository_pull_requests_path(owner: params[:owner], repo: params[:repo]), alert: error.message
  end
end
