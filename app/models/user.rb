class User < ApplicationRecord
  has_many :sessions, dependent: :destroy
  has_many :pr_assessments, dependent: :nullify
  has_many :jev_requests, dependent: :nullify
  has_many :feedbacks, dependent: :destroy
  has_many :pinned_repositories, dependent: :destroy
  has_many :oversized_pull_requests, dependent: :destroy

  before_destroy :destroy_legacy_snapshots, prepend: true

  encrypts :github_token

  def self.from_omniauth(auth)
    find_or_initialize_by(github_uid: auth.uid.to_s).tap do |user|
      user.update!(
        login: auth.info.nickname,
        name: auth.info.name,
        avatar_url: auth.info.image,
        github_token: auth.credentials.token,
        github_created_at: auth.dig(:extra, :raw_info, :created_at)
      )
    end
  end

  def display_name
    name.presence || login
  end

  private
    def destroy_legacy_snapshots
      pr_assessments.where(repository_id: nil).destroy_all
    end
end
