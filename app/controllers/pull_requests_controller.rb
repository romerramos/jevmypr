class PullRequestsController < ApplicationController
  include GithubFrameErrors

  def index
    @repo = params.require(:repo)
    @query = params[:q].to_s.strip
    @pull_requests = github.pull_requests(@repo, query: @query)
    @previous_verdicts = Current.user.pr_assessments.where(repo_full_name: @repo).recent
      .group_by(&:pr_number).transform_values(&:first)
  end

  private
    def frame_id = request.headers["Turbo-Frame"].presence || "pull_requests"
end
