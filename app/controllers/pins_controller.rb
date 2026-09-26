class PinsController < ApplicationController
  def create
    Current.user.pinned_repositories.find_or_create_by(full_name: repo_full_name)
    redirect_to repositories_path(q: params[:q].presence), status: :see_other
  end

  def destroy
    Current.user.pinned_repositories.where(full_name: repo_full_name).destroy_all
    redirect_to repositories_path(q: params[:q].presence), status: :see_other
  end

  private
    def repo_full_name = "#{params[:owner]}/#{params[:repo]}"
end
