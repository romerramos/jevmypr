class DashboardController < ApplicationController
  def show
    @repo = params[:repo].presence
    @recent_assessments = Current.user.pr_assessments.recent.limit(5)
  end
end
