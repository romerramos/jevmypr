# A pull request Jev couldn't read because it's bigger than its context window. Remembered per commit so
# the picker stops offering to ask again (and failing) until the pull request changes.
class OversizedPullRequest < ApplicationRecord
  belongs_to :repository, optional: true # Legacy private marks stay unbound.
  belongs_to :user, optional: true

  validates :repo_full_name, :pr_number, presence: true
  validates :head_sha, presence: true, if: :repository_id?

  scope :for_head, ->(pr) { where(pr_number: pr.number, head_sha: pr.head_sha) }

  def self.record!(repository:, pull_request:)
    create_or_find_by!(repository: repository, pr_number: pull_request.number, head_sha: pull_request.head_sha) do |oversized|
      oversized.repo_full_name = repository.full_name
    end
  end

  def current_for?(pull_request)
    head_sha.present? && head_sha == pull_request.head_sha
  end
end
