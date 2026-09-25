module ApplicationHelper
  def github_sign_in_configured?
    github = Rails.application.credentials.github
    github.present? && github[:client_id].present? && github[:client_secret].present?
  end

  # Where the user grants this OAuth App access to organizations (and sees what it can read).
  def github_app_access_url
    "https://github.com/settings/connections/applications/#{Rails.application.credentials.dig(:github, :client_id)}"
  end
end
