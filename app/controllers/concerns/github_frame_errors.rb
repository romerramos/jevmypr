# Frame endpoints render GitHub problems inside the frame instead of redirecting,
# so the rest of the page keeps working.
module GithubFrameErrors
  extend ActiveSupport::Concern

  # rescue_from checks handlers bottom-up, so the specific Unauthorized handler comes last.
  included do
    rescue_from Github::Client::Error do |error|
      render_frame_error error.message
    end

    rescue_from Github::Client::Unauthorized do |error|
      terminate_session
      render_frame_error error.message, sign_in: true
    end
  end

  private
    def render_frame_error(message, sign_in: false)
      render partial: "shared/frame_error", locals: { frame: frame_id, message: message, sign_in: sign_in }
    end
end
