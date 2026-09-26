# Sign in with GitHub. The OAuth token is kept (encrypted) on the user and used for all GitHub API calls.
# Needs github.client_id and github.client_secret (or GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET) from a GitHub OAuth App,
# callback http://localhost:3000/auth/github/callback).
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github, AppSecrets[:github_client_id], AppSecrets[:github_client_secret], scope: "read:user,repo"
end

OmniAuth.config.logger = Rails.logger
OmniAuth.config.on_failure = ->(env) { OmniAuth::FailureEndpoint.new(env).redirect_to_failure }
