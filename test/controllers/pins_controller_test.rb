require "test_helper"

class PinsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "pinning is idempotent and returns to the list with the search kept" do
    assert_difference -> { users(:one).pinned_repositories.count }, 1 do
      post repository_pin_path(owner: "acme", repo: "web", q: "we")
      post repository_pin_path(owner: "acme", repo: "web")
    end

    assert_redirected_to repositories_path
    post repository_pin_path(owner: "acme", repo: "web", q: "we")
    assert_redirected_to repositories_path(q: "we")
  end

  test "unpinning removes only that repository for this user" do
    users(:one).pinned_repositories.create!(full_name: "acme/web")
    users(:one).pinned_repositories.create!(full_name: "acme/api")
    users(:two).pinned_repositories.create!(full_name: "acme/web")

    delete repository_pin_path(owner: "acme", repo: "web")

    assert_equal [ "acme/api" ], users(:one).pinned_repositories.pluck(:full_name)
    assert users(:two).pinned_repositories.exists?(full_name: "acme/web")
  end

  test "ignores names that aren't a GitHub owner/name" do
    assert_no_difference -> { PinnedRepository.count } do
      post repository_pin_path(owner: "acme", repo: "..")
    end
    assert_redirected_to repositories_path
  end
end
