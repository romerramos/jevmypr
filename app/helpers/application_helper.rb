module ApplicationHelper
  def github_sign_in_configured?
    github = Rails.application.credentials.github
    github.present? && github[:client_id].present? && github[:client_secret].present?
  end

  # Where the user grants this OAuth App access to organizations (and sees what it can read).
  def github_app_access_url
    "https://github.com/settings/connections/applications/#{Rails.application.credentials.dig(:github, :client_id)}"
  end

  # Compact relative time for dense lists: "just now", "5m ago", "3h ago", "4d ago", "Mar 2", "Mar 2023".
  def short_time_ago(time, now: Time.current)
    seconds = (now - time).to_i
    if seconds < 60 then "just now"
    elsif seconds < 1.hour then "#{seconds / 60}m ago"
    elsif seconds < 1.day then "#{seconds / 3600}h ago"
    elsif seconds < 30.days then "#{seconds / 1.day.to_i}d ago"
    else time.strftime(time.year == now.year ? "%b %-d" : "%b %Y")
    end
  end
end
