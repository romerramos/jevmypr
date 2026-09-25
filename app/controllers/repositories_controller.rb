class RepositoriesController < ApplicationController
  include GithubErrors

  def index
    @query = params[:q].to_s.strip
    @repositories = github.repositories(query: @query)
    @recent_assessments = Current.user.pr_assessments.recent.limit(5)
  end

  private
    def default_frame = "repositories"
end
