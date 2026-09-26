class AssessmentsController < ApplicationController
  include Pagy::Method

  rate_limit to: JevAllowance::LIMITS.asks_per_minute_per_user, within: 1.minute, only: :create,
    by: -> { Current.user&.id || request.remote_ip },
    with: -> { redirect_back_or_to repositories_path, alert: "That's a lot of pull requests at once. Wait a minute and try again." }

  def index
    @query = params[:q].to_s.strip
    @verdict = params[:verdict].presence_in(PrAssessment::VERDICTS.keys)
    @counts = Current.user.pr_assessments.group(:choice).count

    scope = Current.user.pr_assessments.recent.search(@query)
    scope = scope.where(choice: @verdict) if @verdict
    @pagy, @assessments = pagy(:offset, scope, limit: 20)
  end

  def show
    @assessment = Current.user.pr_assessments.find(params[:id])
  end

  def create
    repo = "#{params[:owner]}/#{params[:repo]}"
    if (denial = JevAllowance.new(Current.user).denial)
      return redirect_back_or_to repository_pull_requests_path(owner: params[:owner], repo: params[:repo]), alert: denial.message
    end

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
