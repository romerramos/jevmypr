require "test_helper"

class PullRequestsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "lists open pull requests as Ask Jev buttons posting to nested assessments" do
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect"), pull_request_node(number: 9, title: "Bump rails", draft: true) ])

    get repository_pull_requests_path(owner: "acme", repo: "web")

    assert_response :success
    assert_select "title", "Pull requests in acme/web – Jev my PR"
    assert_select "form[action=?][data-turbo-frame='_top']", "/repositories/acme/web/pull_requests/7/assessments"
    assert_select "form[action=?]", "/repositories/acme/web/pull_requests/9/assessments"
    assert_select "button", text: /Fix login redirect/
    assert_select ".badge", "Draft"
    assert_select "a[href=?]", repositories_path, text: /Repositories/
  end

  test "keeps the repository sidebar lazy so the page doesn't wait on the repository list" do
    stub_github_pull_requests([])

    get repository_pull_requests_path(owner: "acme", repo: "web")

    assert_select "aside#repository_sidebar[data-turbo-permanent] turbo-frame#repositories[src=?]", repositories_path
  end

  test "loading states are declared in the markup for the CSS to pick up" do
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect") ])

    get repository_pull_requests_path(owner: "acme", repo: "web")

    assert_select "turbo-frame#pull_request_results[data-loading-label='Loading pull requests…']"
    assert_select "turbo-frame#repositories[data-loading-label='Loading repositories…']"
    assert_select "section[data-visit-loading=pane]"
    assert_select "form.ask-jev", 1
    assert_select ".ask-jev-overlay[role=status]", text: /Jev is reading the diff/
  end

  test "repository names with dots route correctly" do
    stub_github_pull_requests([])

    get "/repositories/acme/acme.github.io/pull_requests"

    assert_response :success
    assert_select "h2", "acme/acme.github.io"
  end

  test "shows the previous verdict for pull requests already assessed" do
    users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 7, pr_title: "Fix login redirect", pr_url: "https://github.com/acme/web/pull/7", choice: "llm_enough")
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect") ])

    get repository_pull_requests_path(owner: "acme", repo: "web")

    assert_select "button", text: /Tagged llm review/
    assert_select "button", text: /Ask again/
  end

  test "search renders into the results frame" do
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect") ])

    get repository_pull_requests_path(owner: "acme", repo: "web", q: "payments"), headers: { "Turbo-Frame" => "pull_request_results" }

    assert_select "turbo-frame#pull_request_results", text: /No open pull requests match “payments”/
  end

  test "GitHub errors render in place" do
    stub_request(:post, "#{ApiStubs::GITHUB}/graphql").to_return(json_response({}, status: 500))

    get repository_pull_requests_path(owner: "acme", repo: "web")

    assert_select "turbo-frame#pull_request_results [role=alert]", text: /GitHub returned HTTP 500/
  end
end
