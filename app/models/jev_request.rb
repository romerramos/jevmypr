# Usage survives account deletion without a requester link. Pending reservations count
# towards the weekly limit; a failed GitHub fetch (no Jev call) does not.
class JevRequest < ApplicationRecord
  # Longer than the bounded GitHub pagination and Jev retry timeouts combined.
  RESERVATION_LIFETIME = 30.minutes
  SOURCES = %w[web api].freeze
  # Long enough for the API's daily per-IP cap; after that the IP hash is forgotten (config/recurring.yml).
  IP_RETENTION = 2.days

  belongs_to :user, optional: true
  belongs_to :repository, optional: true # Migrated usage has no known repository identity.
  has_one :pr_assessment

  validates :source, inclusion: { in: SOURCES }

  scope :from_api, -> { where(source: "api") }

  scope :chargeable, ->(now = Time.current) {
    where.not(sent_at: nil).or(where(state: "pending").where("created_at > ?", now - RESERVATION_LIFETIME))
  }

  # Keyed with the app's secret, so the IP address can't be recovered by hashing every possible address.
  def self.ip_digest(ip)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.key_generator.generate_key("jev_requests/ip_digest"), ip.to_s)
  end

  def self.forget_ips(now: Time.current)
    where(created_at: ...(now - IP_RETENTION)).where.not(ip_digest: nil).update_all(ip_digest: nil)
  end
end
