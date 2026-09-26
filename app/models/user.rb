class User < ApplicationRecord
  has_many :sessions, dependent: :destroy
  has_many :pr_assessments, dependent: :destroy
  has_many :pinned_repositories, dependent: :destroy

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
end
