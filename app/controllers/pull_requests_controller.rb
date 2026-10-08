class PullRequestsController < ApplicationController
  include GithubErrors

  def index
    refresh = params[:refresh].present?
    # The cached lookup only finds the repository; GitHub checks access again when listing its PRs.
    repository = Repository.from_github!(github.repository("#{params[:owner]}/#{params[:repo]}", cached: true, fresh: refresh))
    @repo = repository.full_name
    @query = params[:q].to_s.strip
    @pull_requests = github.pull_requests(@repo, query: @query, github_id: repository.github_id, fresh: refresh)
    @fetched_at = github.fetched_at(:pull_requests)
    history = repository.pr_assessments.recent.group_by(&:pr_number)
    @previous_verdicts = @pull_requests.to_h do |pr|
      snapshots = history.fetch(pr.number, [])
      [ pr.number, snapshots.find { |snapshot| snapshot.current_for?(pr) } || snapshots.first ]
    end
    @oversized = repository.oversized_pull_requests.index_by { |mark| [ mark.pr_number, mark.head_sha ] }
  end

  private
    def default_frame = "pull_request_results"
end
