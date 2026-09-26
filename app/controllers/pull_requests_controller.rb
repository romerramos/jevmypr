class PullRequestsController < ApplicationController
  include GithubErrors

  def index
    @repo = "#{params[:owner]}/#{params[:repo]}"
    @query = params[:q].to_s.strip
    @pull_requests = github.pull_requests(@repo, query: @query)
    @previous_verdicts = Current.user.pr_assessments.where(repo_full_name: @repo).recent
      .group_by(&:pr_number).transform_values(&:first)
    @oversized = Current.user.oversized_pull_requests.where(repo_full_name: @repo).index_by(&:pr_number)
  end

  private
    def default_frame = "pull_request_results"
end
