# Shows GitHub problems where the content would have been: inside the requesting Turbo Frame,
# or as the page itself for a full visit, instead of an error page.
module GithubErrors
  extend ActiveSupport::Concern

  # rescue_from checks handlers bottom-up, so the specific Unauthorized handler comes last.
  included do
    rescue_from Github::Client::Error do |error|
      render_github_error error.message
    end

    rescue_from Github::Client::Unauthorized do |error|
      terminate_session
      render_github_error error.message, sign_in: true
    end
  end

  private
    def render_github_error(message, sign_in: false)
      frame = request.headers["Turbo-Frame"].presence || default_frame
      render "shared/github_error", locals: { frame: frame, message: message, sign_in: sign_in }
    end
end
