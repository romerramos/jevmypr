# Asks Jev whether a pull request needs a human review, based on its description, file list and diff.
#
#   PrReviewDecider.new(github: Github::Client.new(token)).decide("owner/repo", 42)
class PrReviewDecider
  QUESTION_ID = "needs_human_review"
  CHOICES = {
    "yes" => "Risky or complex changes (security, auth, payments, data migrations, architecture, core business logic, " \
             "concurrency) where mistakes are costly. A human must review.",
    "llm_enough" => "Non-trivial but low-risk changes (small features, refactors, tests, contained bug fixes) where an " \
                    "automated LLM review is sufficient.",
    "no" => "Trivial and safe changes (typos, docs, formatting, comments, version bumps, generated files) that need no review."
  }.freeze
  MAX_DIFF_BYTES = 100_000

  Decision = Data.define(:choice, :probabilities, :confidence, :model)
  Result = Data.define(:pull_request, :files, :decision, :diff_truncated)

  def initialize(github:, jev: Jev::Client.new)
    @github = github
    @jev = jev
  end

  def decide(full_name, number)
    pull_request = @github.pull_request(full_name, number)
    files = @github.pull_request_files(full_name, number)
    diff = @github.pull_request_diff(full_name, number).to_s
    truncated = diff.bytesize > MAX_DIFF_BYTES

    response = @jev.ask(state: state_for(full_name, pull_request, files, diff, truncated), questions: { QUESTION_ID => question })

    Result.new(pull_request: pull_request, files: files, decision: decision_from(response), diff_truncated: truncated)
  end

  private
    def question
      {
        type: "choice",
        instructions: "Does this PR need a review from a human?",
        criteria: CHOICES
      }
    end

    def state_for(full_name, pull_request, files, diff, truncated)
      {
        repository: full_name,
        title: pull_request.title,
        description: pull_request.body.to_s.truncate(5_000),
        author: pull_request.author_login,
        base_branch: pull_request.base_ref,
        head_branch: pull_request.head_ref,
        stats: { additions: pull_request.additions, deletions: pull_request.deletions, changed_files: pull_request.changed_files },
        files: files.map { |f| "#{f.status} #{f.filename} (+#{f.additions} -#{f.deletions})" },
        diff: truncated ? diff.byteslice(0, MAX_DIFF_BYTES).scrub("") : diff,
        diff_truncated: truncated
      }
    end

    def decision_from(response)
      answer = response.answers&.dig(QUESTION_ID)
      raise Jev::Client::Error, "Jev didn't answer the review question." unless answer

      choice = answer["choice"]
      raise Jev::Client::Error, "Jev answered with an unknown option: #{choice.inspect}." unless CHOICES.key?(choice)

      Decision.new(choice: choice, probabilities: answer["probabilities"].to_h, confidence: answer["confidence"], model: response.model)
    end
end
