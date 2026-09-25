class User < ApplicationRecord
  has_many :sessions, dependent: :destroy

  encrypts :github_token

  def self.from_omniauth(auth)
    find_or_initialize_by(github_uid: auth.uid.to_s).tap do |user|
      user.update!(
        login: auth.info.nickname,
        name: auth.info.name,
        avatar_url: auth.info.image,
        github_token: auth.credentials.token
      )
    end
  end

  def display_name
    name.presence || login
  end
end
