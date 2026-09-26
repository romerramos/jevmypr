class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private
    def github
      @github ||= if DevelopmentPreview.enabled? && Current.user.github_uid == DevelopmentPreview::UID
        Github::PreviewClient.new
      else
        Github::Client.new(Current.user.github_token)
      end
    end
end
