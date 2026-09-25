require "test_helper"

class RepositoriesControllerTest < ActionDispatch::IntegrationTest
  test "root sends signed-in users to the repository list, and requires sign-in" do
    get root_path
    assert_redirected_to repositories_path

    get repositories_path
    assert_redirected_to new_session_path
  end

  test "lists repositories linking to their nested pull request pages" do
    sign_in_as users(:one)
    stub_github_repositories("acme/web", "acme/secret-api")

    get repositories_path

    assert_response :success
    assert_select "title", "Repositories – Jev my PR"
    assert_select "aside#repository_sidebar[data-turbo-permanent] turbo-frame#repositories a[data-picker-item]", 2
    assert_select "a[href=?][data-turbo-frame=_top]", "/repositories/acme/web/pull_requests"
    assert_select "a[href='/repositories/acme/secret-api/pull_requests'] svg[aria-label='Private']"
    assert_select "#account-menu", text: /Signed in as octocat/
  end

  test "search filters and explains an empty result" do
    sign_in_as users(:one)
    stub_github_repositories("acme/web")

    get repositories_path(q: "billing"), headers: { "Turbo-Frame" => "repositories" }

    assert_select "turbo-frame#repositories", text: /No repositories match “billing”/
  end

  test "shows recent verdicts, only the user's own" do
    user = users(:one)
    user.pr_assessments.create!(repo_full_name: "acme/web", pr_number: 3, pr_title: "Rotate API keys", pr_url: "https://github.com/acme/web/pull/3", choice: "yes")
    users(:two).pr_assessments.create!(repo_full_name: "other/repo", pr_number: 1, pr_title: "Someone else's PR", pr_url: "https://github.com/other/repo/pull/1", choice: "no")
    sign_in_as user
    stub_github_repositories("acme/web")

    get repositories_path

    assert_select "h2", "Your recent verdicts"
    assert_select "a", text: /Rotate API keys/
    assert_select "a", text: /Someone else's PR/, count: 0
  end

  test "links to the app's access settings for missing private or organization repositories" do
    sign_in_as users(:one)
    stub_github_repositories("acme/web")

    get repositories_path

    assert_select "a[href^='https://github.com/settings/connections/applications/']", text: /Review this app's access/
  end

  test "an expired GitHub token signs the user out and offers to sign in again" do
    sign_in_as users(:one)
    stub_request(:get, "#{ApiStubs::GITHUB}/user/repos").with(query: hash_including({})).to_return(json_response({}, status: 401))

    get repositories_path, headers: { "Turbo-Frame" => "repositories" }

    assert_select "turbo-frame#repositories a[href=?][data-turbo-frame='_top']", new_session_path
    assert_empty cookies[:session_id]
  end
end
