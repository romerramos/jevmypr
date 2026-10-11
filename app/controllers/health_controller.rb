# /up for load balancers and uptime monitors, plus the running version, so bin/update can tell that the
# release it just started is the one answering.
class HealthController < Rails::HealthController
  before_action { response.set_header(ReleaseUpdate::VERSION_HEADER, Rails.application.config.x.version) }
end
