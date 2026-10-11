require "test_helper"

class JevRequestTest < ActiveSupport::TestCase
  test "hashes IP addresses with the app's secret" do
    digest = JevRequest.ip_digest("203.0.113.7")

    assert_equal digest, JevRequest.ip_digest("203.0.113.7")
    assert_not_equal digest, JevRequest.ip_digest("203.0.113.8")
    assert_not_equal Digest::SHA256.hexdigest("203.0.113.7"), digest
    assert_no_match "203.0.113.7", digest
  end

  test "forgets IP hashes after IP_RETENTION" do
    now = Time.current
    old = JevRequest.create!(source: "api", ip_digest: "old", created_at: now - JevRequest::IP_RETENTION - 1.minute)
    recent = JevRequest.create!(source: "api", ip_digest: "recent", created_at: now - 1.day)

    JevRequest.forget_ips(now: now)

    assert_nil old.reload.ip_digest
    assert_equal "recent", recent.reload.ip_digest
  end

  test "the database allows only one pending ordinary request per sent diff" do
    JevRequest.create!(source: "api", diff_sha256: "abc")
    JevRequest.create!(source: "api", diff_sha256: "abc", fresh: true)
    JevRequest.create!(source: "api", diff_sha256: "abc", state: "failed")

    assert_raises(ActiveRecord::RecordNotUnique) { JevRequest.create!(source: "api", diff_sha256: "abc") }
  end

  test "knows only web and api requests" do
    assert_not JevRequest.new(source: "other").valid?
    assert_equal "web", JevRequest.new.source
  end
end
