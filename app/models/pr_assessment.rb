class PrAssessment < ApplicationRecord
  # Class names are spelled out in full so Tailwind can find them.
  VERDICTS = {
    "yes" => { label: "Human review", headline: "Get a human on this.", icon: "user-round-check",
               summary: "Jev found changes where a mistake would be costly. Ask a teammate to review before merging.",
               status_class: "status-error", progress_class: "progress-error" },
    "llm_enough" => { label: "LLM review", headline: "An LLM review is enough.", icon: "bot",
                      summary: "The changes are real but low-risk. An automated LLM review should catch what matters.",
                      status_class: "status-warning", progress_class: "progress-warning" },
    "no" => { label: "No review", headline: "Safe to merge without review.", icon: "check",
              summary: "Jev found only trivial changes. Nobody needs to review this one.",
              status_class: "status-success", progress_class: "progress-success" }
  }.freeze

  belongs_to :user

  validates :repo_full_name, :pr_number, :pr_title, :pr_url, presence: true
  validates :choice, inclusion: { in: VERDICTS.keys }
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
      additions: pull_request.additions.to_i,
      deletions: pull_request.deletions.to_i,
      changed_files: pull_request.changed_files.to_i,
      files: result.files.map(&:to_h),
      choice: decision.choice,
      probabilities: decision.probabilities,
      confidence: decision.confidence,
      jev_model: decision.model,
      diff_truncated: result.diff_truncated
    )
  end

  def verdict
    VERDICTS.fetch(choice)
  end

  # Probabilities in a fixed order (human, LLM, none) so the rows line up with the tag strips.
  def ranked_probabilities
    VERDICTS.map { |key, verdict| [ key, verdict, probabilities.to_h[key].to_f ] }
  end
end
