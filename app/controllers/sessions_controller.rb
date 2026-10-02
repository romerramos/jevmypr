class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create failure preview ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Too many sign-in attempts. Wait a few minutes and try again." }

  def new
    redirect_to repositories_path if authenticated?
  end

  # Local sample sign-in. DevelopmentPreview.enabled? is false in production and
  # whenever GitHub and Jev credentials are both present, so this route is a 404 there.
  def preview
    raise ActionController::RoutingError, "Not Found" unless DevelopmentPreview.enabled?

    start_new_session_for DevelopmentPreview.user
    redirect_to after_authentication_url, notice: "Preview mode: sample repositories, no GitHub or Jev calls."
  end

  def create
    user = User.from_omniauth(request.env["omniauth.auth"])
    start_new_session_for user
    redirect_to after_authentication_url
  end

  def failure
    redirect_to new_session_path, alert: "GitHub sign-in didn't finish (#{params[:message].to_s.humanize.downcase.presence || "unknown error"}). Try again."
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
