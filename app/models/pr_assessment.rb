class PrAssessment < ApplicationRecord
  # Class names are spelled out in full so Tailwind can find them.
  VERDICTS = {
    "yes" => { label: "Human review", needs: "a human review", headline: "Get a human on this.", icon: "user-round-check",
               summary: "Jev thinks a human reviewer would be useful here. Consider asking a teammate to take a look before merging.",
               status_class: "status-error", progress_class: "progress-error" },
    "llm_enough" => { label: "LLM review", needs: "an LLM review", headline: "An LLM review is enough.", icon: "bot",
                      summary: "The changes are real but low-risk. An automated LLM review should catch what matters.",
                      status_class: "status-warning", progress_class: "progress-warning" },
    "no" => { label: "No review", needs: "no review", headline: "Safe to merge without review.", icon: "check",
              summary: "Jev found only trivial changes. Nobody needs to review this one.",
              status_class: "status-success", progress_class: "progress-success" }
  }.freeze
  # Why a file has no verdict of its own, kept short enough to sit where its verdict would be.
  FILE_SKIPS = {
    "no_patch" => { label: "No diff", title: "GitHub has no text diff for this file (binary or very large)." },
    "too_large" => { label: "Not read", title: "Left out to keep the pull request within what Jev can read at once." },
    "too_many" => { label: "Not read", title: "Jev answers for the first #{PrReviewDecider::MAX_FILE_QUESTIONS} files with a diff." },
    "no_answer" => { label: "No answer", title: "Jev didn't answer for this file." }
  }.freeze

  # How many of your rated verdicts you agreed with, and which way Jev was off when you didn't:
  # needed_more is the miss that matters (you'd have wanted more review than Jev said).
  FeedbackSummary = Data.define(:rated, :agreed, :needed_more, :needed_less)
  MAX_FEEDBACK_REASON = 1_000

  belongs_to :user

  validates :repo_full_name, :pr_number, :pr_title, :pr_url, presence: true
  validates :choice, inclusion: { in: VERDICTS.keys }
  validates :feedback_choice, inclusion: { in: VERDICTS.keys }, allow_nil: true
  validates :feedback_reason, length: { maximum: MAX_FEEDBACK_REASON }
  validates :pr_url, format: { with: %r{\Ahttps://github\.com/[\w.-]+/[\w.-]+/pull/\d+\z}, message: "must be a github.com pull request URL" }

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  # Every term must match: "#42" or "42" a PR number, anything else the title or repository.
  scope :search, ->(query) {
    query.to_s.split.reduce(all) do |scope, term|
      if (number = term.delete_prefix("#")).match?(/\A\d+\z/)
        scope.where(pr_number: number.to_i)
      else
        pattern = "%#{sanitize_sql_like(term)}%"
        scope.where("pr_title LIKE :pattern ESCAPE '\\' OR repo_full_name LIKE :pattern ESCAPE '\\'", pattern: pattern)
      end
    end
  }

  def self.feedback_summary
    votes = where.not(feedback_choice: nil).pluck(:choice, :feedback_choice)
    rank = VERDICTS.keys.reverse # "no", "llm_enough", "yes": more review further along
    FeedbackSummary.new(
      rated: votes.size,
      agreed: votes.count { |choice, vote| choice == vote },
      needed_more: votes.count { |choice, vote| rank.index(vote) > rank.index(choice) },
      needed_less: votes.count { |choice, vote| rank.index(vote) < rank.index(choice) }
    )
  end

  def self.from_result(user:, repo_full_name:, result:)
    pull_request = result.pull_request
    decision = result.decision

    new(
      user: user,
      repo_full_name: repo_full_name,
      pr_number: pull_request.number,
      pr_title: pull_request.title,
      pr_url: pull_request.html_url,
      pr_author: pull_request.author_login,
      head_sha: pull_request.head_sha,
      additions: pull_request.additions.to_i,
      deletions: pull_request.deletions.to_i,
      changed_files: pull_request.changed_files.to_i,
      files: result.files.map { |verdict| file_entry(verdict) },
      choice: decision.choice,
      probabilities: decision.probabilities,
      confidence: decision.confidence,
      jev_model: decision.model,
      diff_truncated: result.diff_truncated,
      input_tokens: result.usage["input_tokens"].to_i,
      output_tokens: result.usage["output_tokens"].to_i
    )
  end

  # The file's metadata plus Jev's verdict for it, or why there is none. Patches aren't stored.
  def self.file_entry(verdict)
    file = verdict.file
    entry = { "filename" => file.filename, "status" => file.status, "additions" => file.additions, "deletions" => file.deletions }
    if (decision = verdict.decision)
      entry.merge("choice" => decision.choice, "probabilities" => decision.probabilities, "confidence" => decision.confidence)
    else
      entry.merge("skipped" => verdict.skipped.to_s)
    end
  end

  def verdict
    VERDICTS.fetch(choice)
  end

  # Your vote on Jev's verdict: Jev's own choice to agree, or the one it should have been.
  # A reason only goes with a disagreement.
  def record_feedback!(choice:, reason: nil)
    update!(feedback_choice: choice, feedback_reason: (reason.to_s.strip.presence unless choice == self.choice),
            feedback_at: Time.current)
  end

  def clear_feedback!
    update!(feedback_choice: nil, feedback_reason: nil, feedback_at: nil)
  end

  def feedback? = feedback_choice.present?
  def agreed? = feedback? && feedback_choice == choice
  def disagreed? = feedback? && !agreed?

  # Files that need the most attention first (human, LLM, none, then those without a verdict),
  # keeping GitHub's order within each group.
  def files_by_verdict
    rank = VERDICTS.keys
    files.each_with_index.sort_by { |file, i| [ rank.index(file["choice"]) || rank.size, i ] }.map(&:first)
  end

  # How many files got each verdict, in the order of VERDICTS.
  def file_verdict_counts
    tally = files.filter_map { |file| file["choice"] }.tally
    VERDICTS.filter_map { |key, verdict| [ key, verdict, tally[key] ] if tally[key] }
  end

  # Whether this verdict was given for the pull request's current code. Verdicts saved before
  # head SHAs were recorded count as current: re-asking costs tokens, so it stays an explicit choice.
  def current_for?(pull_request)
    head_sha.blank? || head_sha == pull_request.head_sha
  end

  # Probabilities in a fixed order (human, LLM, none) so the rows line up with the tag strips.
  def ranked_probabilities
    VERDICTS.map { |key, verdict| [ key, verdict, probabilities.to_h[key].to_f ] }
  end
end
