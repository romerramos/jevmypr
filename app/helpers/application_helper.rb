module ApplicationHelper
  BUY_ME_A_COFFEE_URL = "https://buymeacoffee.com/romerramos".freeze

  def github_sign_in_configured?
    AppSecrets[:github_client_id].present? && AppSecrets[:github_client_secret].present?
  end

  # Where the user grants this OAuth App access to organizations (and sees what it can read).
  def github_app_access_url
    "https://github.com/settings/connections/applications/#{AppSecrets[:github_client_id]}"
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

  # Link to the maintainer's Buy Me a Coffee page. The icon is for standalone links, not running text.
  def coffee_link(text, icon: true, **options)
    link_to BUY_ME_A_COFFEE_URL, target: "_blank", rel: "noopener", **options do
      icon ? safe_join([ lucide_icon("coffee", class: "size-4 shrink-0", "aria-hidden": true), text ], " ") : text
    end
  end
end
