# Usage survives account deletion without a requester link. Pending reservations count
# towards the weekly limit; a failed GitHub fetch (no Jev call) does not.
class JevRequest < ApplicationRecord
  # Longer than the bounded GitHub pagination and Jev retry timeouts combined.
  RESERVATION_LIFETIME = 30.minutes

  belongs_to :user, optional: true
  belongs_to :repository, optional: true # Migrated usage has no known repository identity.
  has_one :pr_assessment

  scope :chargeable, ->(now = Time.current) {
    where.not(sent_at: nil).or(where(state: "pending").where("created_at > ?", now - RESERVATION_LIFETIME))
  }
end
