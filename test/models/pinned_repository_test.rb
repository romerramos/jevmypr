require "test_helper"

class PinnedRepositoryTest < ActiveSupport::TestCase
  test "requires a GitHub owner/name, once per user" do
    user = users(:one)
    assert user.pinned_repositories.create(full_name: "acme/web.site").persisted?
    assert_not user.pinned_repositories.new(full_name: "acme/web.site").valid?
    assert_not user.pinned_repositories.new(full_name: "acme").valid?
    assert_not user.pinned_repositories.new(full_name: "acme/..").valid?
    assert users(:two).pinned_repositories.new(full_name: "acme/web.site").valid?
  end
end
