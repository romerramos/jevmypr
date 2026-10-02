class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private
    def previewing?
      DevelopmentPreview.enabled? && Current.user&.github_uid == DevelopmentPreview::UID
    end
    helper_method :previewing?

    def github
      @github ||= previewing? ? Github::PreviewClient.new : Github::Client.new(Current.user.github_token)
    end
end
