class AssessmentsController < ApplicationController
  include Pagy::Method
  include GithubErrors

  before_action :prepare_analysis, only: :create

  # Saved results are resolved before this new-analysis throttle or any allowance check.
  rate_limit to: JevAllowance::LIMITS.asks_per_minute_per_user, within: 1.minute, only: :create,
    by: -> { Current.user&.id || request.remote_ip },
    with: -> { redirect_back_or_to repositories_path, alert: "That's a lot of pull requests at once. Wait a minute and try again." }

  TOO_BIG_MESSAGE = "That pull request is too big for Jev to read in one go, so it's marked “Too big”. " \
                    "It deserves a human review anyway. If it gets smaller, you can ask Jev again."

  def index
    @query = params[:q].to_s.strip
    @verdict = params[:verdict].presence_in(PrAssessment::VERDICTS.keys)
    accessible = PrAssessment.accessible_to(user: Current.user, github: github)
    @counts = accessible.group(:choice).count
    @feedback = Current.user.feedbacks.where(pr_assessment_id: accessible.select(:id)).summary

    scope = accessible.recent.search(@query)
    scope = scope.where(choice: @verdict) if @verdict
    @pagy, @assessments = pagy(:offset, scope, limit: 20)
  end

  def show
    @assessment = PrAssessment.find(params[:id]).verify_access!(user: Current.user, github: github)
    @feedback = Current.user.feedbacks.find_or_initialize_by(pr_assessment: @assessment)
  end

  def create
    assessment = PrAssessmentCreator.new(user: Current.user, repository: @repository, github: github, jev: jev,
                                         fresh: fresh_analysis?).call(@pull_request)

    redirect_to assessment_path(assessment)
  rescue PrReviewDecider::TooLarge
    redirect_to repository_pull_requests_path(owner: params[:owner], repo: params[:repo]), alert: TOO_BIG_MESSAGE
  rescue Jev::Client::Error, PrAssessmentCreator::NotAllowed, PrAssessmentCreator::InProgress => error
    redirect_to repository_pull_requests_path(owner: params[:owner], repo: params[:repo]), alert: error.message
  end

  private
    def prepare_analysis
      @repository = Repository.from_github!(github.repository("#{params[:owner]}/#{params[:repo]}"))
      @pull_request = github.pull_request(@repository.github_id, params[:pull_request_number])
      raise Github::Client::Error, "GitHub didn't return the pull request's current commit." if @pull_request.head_sha.blank?
      return if fresh_analysis?

      if (saved = @repository.pr_assessments.for_head(@pull_request).recent.first)
        redirect_to assessment_path(saved)
      elsif @repository.oversized_pull_requests.for_head(@pull_request).exists?
        redirect_to repository_pull_requests_path(owner: params[:owner], repo: params[:repo]), alert: TOO_BIG_MESSAGE
      end
    end

    def fresh_analysis? = params[:fresh] == "1"

    def jev
      previewing? ? Jev::PreviewClient.new : Jev::Client.new
    end

    def default_frame = "verdicts"

    def render_github_error(message, sign_in: false)
      if action_name == "create"
        destination = sign_in ? new_session_path : repository_pull_requests_path(owner: params[:owner], repo: params[:repo])
        redirect_to destination, alert: message
      else
        super
      end
    end
end
