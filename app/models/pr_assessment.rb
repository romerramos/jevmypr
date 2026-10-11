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

  belongs_to :repository, optional: true # Unbound legacy snapshots are retained, not published.
  belongs_to :user, optional: true # Requester attribution is removed on account deletion.
  belongs_to :jev_request, optional: true
  has_many :feedbacks, dependent: :destroy

  validates :repo_full_name, :pr_number, :pr_title, :pr_url, presence: true
  validates :head_sha, presence: true, if: :repository_id?
  validates :choice, inclusion: { in: VERDICTS.keys }
  validates :pr_url, format: { with: %r{\Ahttps://github\.com/[\w.-]+/[\w.-]+/pull/\d+\z}, message: "must be a github.com pull request URL" }

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :for_head, ->(pr) { where(pr_number: pr.number, head_sha: pr.head_sha) }

  # Every term must match: "#42" or "42" a PR number, anything else the title or repository.
  scope :search, ->(query) {
    query.to_s.split.reduce(all) do |scope, term|
      if (number = term.delete_prefix("#")).match?(/\A\d+\z/)
        scope.where(pr_number: number.to_i)
      else
        pattern = "%#{sanitize_sql_like(term)}%"
        scope.left_joins(:repository).where("pr_title LIKE :pattern ESCAPE '\\' OR repo_full_name LIKE :pattern ESCAPE '\\' OR repositories.full_name LIKE :pattern ESCAPE '\\'", pattern: pattern)
      end
    end
  }

  # For lists of saved verdicts. The viewer's repository list, read with their own token, is the
  # proof of access; it is cached for a few minutes and `fresh: true` re-reads it. A single
  # verdict and votes on it still check the repository live (verify_access!).
  def self.accessible_to(user:, github:, fresh: false)
    remote = github.repositories(fresh: fresh).index_by(&:github_id)
    ids = Repository.where(github_id: remote.keys).map do |repo|
      repo.update!(full_name: remote[repo.github_id].full_name) if repo.full_name != remote[repo.github_id].full_name
      repo.id
    end
    # Compatibility only: the original owner may still read private legacy history while the
    # name is visible to them. Never bind these snapshots to a repository ID.
    visible = remote.values.to_set { |repo| repo.full_name.downcase }
    legacy_names = user.pr_assessments.where(repository_id: nil).distinct.pluck(:repo_full_name).select do |name|
      visible.include?(name.downcase) || github.repository(name, cached: true, fresh: fresh)
    rescue Github::Client::NotFound
      false
    end
    where(repository_id: ids).or(where(repository_id: nil, user_id: user.id, repo_full_name: legacy_names)).includes(:repository)
  end

  def verify_access!(user:, github:)
    if repository
      repository.verify_access!(github)
    else
      raise ActiveRecord::RecordNotFound unless user_id == user.id

      github.repository(repo_full_name) # Owner-only compatibility; no identity backfill.
    end
    self
  end

  def repository_full_name = repository&.full_name || repo_full_name

  def self.from_result(user:, repository:, result:)
    pull_request = result.pull_request
    decision = result.decision

    new(
      user: user,
      repository: repository,
      repo_full_name: repository.full_name,
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

  # Only an exact, known commit is reusable. Unknown legacy SHAs are not a wildcard.
  def current_for?(pull_request)
    head_sha.present? && head_sha == pull_request.head_sha
  end

  # Probabilities in a fixed order (human, LLM, none) so the rows line up with the tag strips.
  def ranked_probabilities
    VERDICTS.map { |key, verdict| [ key, verdict, probabilities.to_h[key].to_f ] }
  end
end
