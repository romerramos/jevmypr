# Sign in with GitHub. The OAuth token is kept (encrypted) on the user and used for all GitHub API calls.
# Needs credentials: github.client_id and github.client_secret (GitHub OAuth App,
# callback http://localhost:3000/auth/github/callback).
Rails.application.config.middleware.use OmniAuth::Builder do
  github = Rails.application.credentials.github || {}

  provider :github, github[:client_id], github[:client_secret], scope: "read:user,repo"
end

OmniAuth.config.logger = Rails.logger
OmniAuth.config.on_failure = ->(env) { OmniAuth::FailureEndpoint.new(env).redirect_to_failure }
