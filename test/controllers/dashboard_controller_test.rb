require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  test "requires sign-in" do
    get root_path

    assert_redirected_to new_session_path
  end

  test "shows the picker with lazy repository and pull request panes" do
    sign_in_as users(:one)

    get root_path

    assert_response :success
    assert_select "h1", "Which PR should Jev triage?"
    assert_select "turbo-frame#repositories[src=?]", repositories_path
    assert_select "turbo-frame#pull_requests:not([src])", text: /Choose a repository/
    assert_select "#account-menu", text: /Signed in as octocat/
  end

  test "preloads the pull requests of the repository in the URL" do
    sign_in_as users(:one)

    get root_path(repo: "acme/web")

    assert_select "turbo-frame#pull_requests[src=?]", pull_requests_path(repo: "acme/web")
  end

  test "lists the user's recent verdicts" do
    user = users(:one)
    user.pr_assessments.create!(repo_full_name: "acme/web", pr_number: 3, pr_title: "Rotate API keys", pr_url: "https://github.com/acme/web/pull/3", choice: "yes")
    users(:two).pr_assessments.create!(repo_full_name: "other/repo", pr_number: 1, pr_title: "Someone else's PR", pr_url: "https://github.com/other/repo/pull/1", choice: "no")
    sign_in_as user

    get root_path

    assert_select "h2", "Your recent verdicts"
    assert_select "a", text: /Rotate API keys/
    assert_select "a", text: /Someone else's PR/, count: 0
  end
end
