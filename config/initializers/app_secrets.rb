# Where the app's secrets come from: Rails credentials first, then environment variables
# (handy for Docker, Kamal, CI or hosts without a credentials file). See config/credentials.example.yml.
module AppSecrets
  SOURCES = {
    github_client_id: [ %i[github client_id], "GITHUB_CLIENT_ID" ],
    github_client_secret: [ %i[github client_secret], "GITHUB_CLIENT_SECRET" ],
    typesafe_api_key: [ %i[typesafe api_key], "TYPESAFE_API_KEY" ]
  }.freeze

  def self.[](name)
    path, env_var = SOURCES.fetch(name)
    Rails.application.credentials.dig(*path).presence || ENV[env_var].presence
  end
end
