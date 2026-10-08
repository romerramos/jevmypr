class RepositoriesController < ApplicationController
  include GithubErrors

  def index
    @query = params[:q].to_s.strip
    @pinned = Current.user.pinned_repositories.pluck(:full_name).to_set
    @repositories = github.repositories(query: @query).partition { |repo| @pinned.include?(repo.full_name) }.flatten
    @recent_assessments = PrAssessment.accessible_to(user: Current.user, github: github).recent.limit(5)
  end

  private
    def default_frame = "repositories"
end
