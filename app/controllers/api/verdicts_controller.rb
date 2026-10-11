module Api
  # The open JSON API: send a diff, get Jev's verdict. No session, cookie or API key, so other tools
  # can call it directly. The same diff sent again reuses its verdict for free.
  #
  #   curl -X POST https://jevmypr.romerramos.me/api/verdicts -H "Content-Type: application/json" \
  #     -d '{"title": "Fix typo", "files": [{"filename": "README.md", "patch": "@@ -1 +1 @@\n-teh\n+the"}]}'
  class VerdictsController < ActionController::API
    # A retry any sooner would only hit the rate limit.
    IN_PROGRESS_RETRY_AFTER = JevAllowance::LIMITS.api_calls_window
    # Room for DiffPayload::MAX_PATCH_BYTES of patches once JSON escapes them, and the rest of the payload.
    MAX_BODY_BYTES = 2 * DiffPayload::MAX_PATCH_BYTES
    BUDGET_DENIALS = %i[monthly_budget api_budget].freeze

    wrap_parameters false
    # Only new verdicts count, but the diff's hash isn't known before the body is read, so every call does here.
    rate_limit to: JevAllowance::LIMITS.api_calls_per_ip, within: JevAllowance::LIMITS.api_calls_window, by: -> { request.remote_ip },
      with: -> { render_error :rate_limited, "That's a lot of diffs at once. Wait #{JevAllowance::LIMITS.api_calls_window.inspect} and try again.",
                              :too_many_requests, retry_at: JevAllowance::LIMITS.api_calls_window.from_now }

    before_action :reject_oversized_body

    rescue_from ActionDispatch::Http::Parameters::ParseError do
      render_error :invalid_json, "The request body isn't valid JSON.", :bad_request
    end

    def create
      payload = DiffPayload.new(params.permit(*DiffPayload::PERMITTED))
      unless payload.valid?
        return render_error(:invalid_diff, payload.error_messages.to_sentence, :unprocessable_content, details: payload.error_messages)
      end

      verdict = PrAssessmentCreator.new(user: nil, repository: nil, github: nil, jev: jev,
                                        ip_digest: JevRequest.ip_digest(request.remote_ip)).call_for_diff(payload)
      render json: verdict.as_json.merge(url: nil)
    rescue PrReviewDecider::TooLarge
      render_error :too_large, "This diff is too big for Jev to read in one go. It deserves a human review anyway.", :content_too_large
    rescue PrAssessmentCreator::InProgress
      render_error :in_progress, "A verdict for this diff is already being prepared. Try again in a moment.", :conflict,
                   retry_at: IN_PROGRESS_RETRY_AFTER.from_now
    rescue PrAssessmentCreator::NotAllowed => error
      if BUDGET_DENIALS.include?(error.denial.reason)
        render_error :budget_paused, error.denial.message, :service_unavailable, retry_at: error.denial.retry_at
      else
        render_error :not_allowed, error.denial.message, :too_many_requests, retry_at: error.denial.retry_at
      end
    rescue Jev::Client::Error => error
      render_error :jev_unavailable, error.message, :bad_gateway
    end

    private
      # Before the body is parsed. A body sent without a length is read only as far as the limit.
      def reject_oversized_body
        return if body_size <= MAX_BODY_BYTES

        render_error :body_too_large, "The request body is over #{MAX_BODY_BYTES / 1_000_000} MB. Send at most " \
                     "#{DiffPayload::MAX_PATCH_BYTES / 1_000_000} MB of patches.", :content_too_large
      end

      def body_size
        return request.content_length if request.content_length

        body = request.body or return 0
        body.read(MAX_BODY_BYTES + 1).to_s.bytesize.tap { body.rewind }
      end

      def jev
        DevelopmentPreview.enabled? ? Jev::PreviewClient.new : Jev::Client.new
      end

      def render_error(code, message, status, retry_at: nil, details: nil)
        response.headers["Retry-After"] = [ (retry_at - Time.current).ceil, 1 ].max.to_s if retry_at
        render json: { error: code, message: message, details: details }.compact, status: status
      end
  end
end
