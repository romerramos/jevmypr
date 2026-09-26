# A pull request Jev couldn't read because it's bigger than its context window. Remembered per commit so
# the picker stops offering to ask again (and failing) until the pull request changes.
class OversizedPullRequest < ApplicationRecord
  belongs_to :user

  validates :repo_full_name, :pr_number, presence: true

  def self.record!(user:, repo_full_name:, pull_request:)
    find_or_initialize_by(user: user, repo_full_name: repo_full_name, pr_number: pull_request.number)
      .tap { |oversized| oversized.update!(head_sha: pull_request.head_sha) }
  end

  def current_for?(pull_request)
    head_sha.blank? || head_sha == pull_request.head_sha
  end
end
