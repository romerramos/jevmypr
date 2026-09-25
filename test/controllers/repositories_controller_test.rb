require "test_helper"

class RepositoriesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "lists repositories inside the frame and marks the selected one" do
    stub_github_repositories("acme/web", "acme/secret-api")

    get repositories_path(repo: "acme/web")

    assert_response :success
    assert_select "turbo-frame#repositories a[data-repo]", 2
    assert_select "a[data-repo='acme/web'][aria-current]"
    assert_select "a[data-repo='acme/secret-api'] svg[aria-label='Private']"
  end

  test "filters by search terms and explains an empty result" do
    stub_github_repositories("acme/web")

    get repositories_path(q: "billing")

    assert_select "turbo-frame#repositories", text: /No repositories match “billing”/
  end

  test "an expired GitHub token signs the user out and offers to sign in again" do
    stub_request(:get, "#{ApiStubs::GITHUB}/user/repos").with(query: hash_including({})).to_return(json_response({}, status: 401))

    get repositories_path

    assert_select "turbo-frame#repositories a[href=?][data-turbo-frame='_top']", new_session_path
    assert_empty cookies[:session_id]
  end
end
