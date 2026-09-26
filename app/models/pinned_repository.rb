class PinnedRepository < ApplicationRecord
  belongs_to :user

  validates :full_name, format: { with: Github::Client::FULL_NAME }, uniqueness: { scope: :user_id }
  validate { errors.add(:full_name, :invalid) if full_name.to_s.include?("..") }
end
