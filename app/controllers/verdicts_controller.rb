# A verdict for a diff sent to the open API, for anyone with its link: no sign-in, read-only. A wrong or
# expired token is a 404, and the page stays out of search engines, caches and Referer headers.
class VerdictsController < ApplicationController
  allow_unauthenticated_access
  before_action :keep_link_private

  TOKEN_FORMAT = /\A[1-9A-HJ-NP-Za-km-z]{24}\z/ # SecureRandom.base58(24), see PrAssessment

  def show
    raise ActiveRecord::RecordNotFound unless params[:token].to_s.match?(TOKEN_FORMAT)

    @assessment = PrAssessment.api.live.find_by!(token: params[:token])
  end

  private
    def keep_link_private
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
      response.headers["X-Robots-Tag"] = "noindex, nofollow"
    end
end
