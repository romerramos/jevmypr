module ApplicationHelper
  def github_sign_in_configured?
    github = Rails.application.credentials.github
    github.present? && github[:client_id].present? && github[:client_secret].present?
  end
end
