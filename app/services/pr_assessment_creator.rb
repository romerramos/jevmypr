# Coalesces ordinary requests across processes with a short SQLite transaction, then
# releases the write lock before any network calls. Explicit fresh requests are separate.
class PrAssessmentCreator
  class InProgress < StandardError
    def initialize
      super("A verdict for this commit is already being prepared. Open the pull request again in a moment.")
    end
  end
  class NotAllowed < StandardError; end

  def initialize(user:, repository:, github:, jev:, fresh: false)
    @user, @repository, @github, @jev, @fresh = user, repository, github, jev, fresh
  end

  def call(pull_request)
    @pull_request = pull_request
    reserved = reserve
    return reserved if reserved.is_a?(PrAssessment)

    @request = reserved
    perform
  end

  private
    def reserve
      JevRequest.transaction do
        unless @fresh
          if (saved = @repository.pr_assessments.for_head(@pull_request).recent.first)
            return saved
          end
          if @repository.oversized_pull_requests.for_head(@pull_request).exists?
            raise PrReviewDecider::TooLarge, @pull_request
          end
        end

        pending = JevRequest.where(repository: @repository, pr_number: @pull_request.number,
                                   head_sha: @pull_request.head_sha, fresh: false, state: "pending")
        pending.where(created_at: ..JevRequest::RESERVATION_LIFETIME.ago).update_all(state: "failed")
        raise InProgress if !@fresh && pending.exists?
        if (denial = JevAllowance.new(@user).denial)
          raise NotAllowed, denial.message
        end

        JevRequest.create!(user: @user, repository: @repository, pr_number: @pull_request.number,
                           head_sha: @pull_request.head_sha, fresh: @fresh)
      end
    rescue ActiveRecord::RecordNotUnique
      raise InProgress
    end

    def perform
      files = @github.pull_request_files(@repository.github_id, @pull_request.number)
      current = @github.pull_request(@repository.github_id, @pull_request.number)
      unless current.head_sha == @pull_request.head_sha
        raise Github::Client::Error, "The pull request changed while its diff was loading. Open it again to assess the new commit."
      end

      @request.update!(sent_at: Time.current)
      result = PrReviewDecider.new(github: @github, jev: @jev).decide(@repository.full_name, @pull_request.number,
        pull_request: @pull_request, files: files) do |usage|
        # Account for a paid response even if its answers turn out to be invalid.
        @request.update!(input_tokens: usage["input_tokens"].to_i, output_tokens: usage["output_tokens"].to_i)
      end

      JevRequest.transaction do
        @request.reload # The requester may have deleted their account during the network call.
        assessment = PrAssessment.from_result(user: @request.user, repository: @repository, result: result)
        assessment.jev_request = @request
        assessment.save!
        @request.update!(state: "succeeded")
        assessment
      end
    rescue PrReviewDecider::TooLarge
      JevRequest.transaction do
        OversizedPullRequest.record!(repository: @repository, pull_request: @pull_request)
        @request.update!(state: "oversized")
      end
      raise
    rescue StandardError
      @request.update!(state: "failed")
      raise
    end
end
