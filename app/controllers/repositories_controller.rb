class RepositoriesController < ApplicationController
  include GithubFrameErrors

  def index
    @query = params[:q].to_s.strip
    @selected = params[:repo]
    @repositories = github.repositories(query: @query)
  end

  private
    def frame_id = "repositories"
end
