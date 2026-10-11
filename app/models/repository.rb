class Repository < ApplicationRecord
  has_many :pr_assessments
  has_many :oversized_pull_requests

  # GitHub IDs are positive. Negative IDs are reserved for local development samples.
  validates :github_id, numericality: { only_integer: true, other_than: 0 }
  validates :full_name, format: { with: Github::Client::FULL_NAME }

  def self.from_github!(remote)
    create_or_find_by!(github_id: remote.github_id) { |repo| repo.full_name = remote.full_name }.tap do |repo|
      repo.update!(full_name: remote.full_name) if repo.full_name != remote.full_name
    end
  end

  # Always a live read with the viewer's token, by ID. Names, pins and cached lists
  # can help find a repository, but cannot grant access to its saved verdicts.
  def verify_access!(github)
    remote = github.repository(github_id)
    raise Github::Client::NotFound, "That repository isn't visible to you." unless remote.github_id == github_id

    update!(full_name: remote.full_name) if full_name != remote.full_name
    self
  end
end
