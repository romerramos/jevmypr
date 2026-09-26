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
    assert_select "header a[href=?]", repositories_path, text: /All repositories/
    assert_select "header h1", text: /acme\s*web/
    assert_select "h2", text: /acme\s*web/
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
    assert_select "h2 .font-semibold", "acme.github.io"
  end

  test "a verdict for the same commit is reopened for free instead of asking Jev again" do
    current = assess(7, choice: "llm_enough", head_sha: "sha-7")
    assess(8, choice: "yes", head_sha: "old-sha")
    legacy = assess(9, choice: "no", head_sha: nil)
    stub_github_pull_requests([ 7, 8, 9, 10 ].map { |n| pull_request_node(number: n, title: "PR #{n}", head_sha: "sha-#{n}") })

    get repository_pull_requests_path(owner: "acme", repo: "web")

    assert_select "a[href=?]", assessment_path(current), text: /PR 7.*Tagged llm review.*View verdict/m
    assert_select "a[href=?]", assessment_path(legacy), text: /View verdict/
    assert_select "form.ask-jev[action=?] button", "/repositories/acme/web/pull_requests/8/assessments", text: /Tagged human review, changed since.*Ask again/m
    assert_select "form.ask-jev[action=?] button", "/repositories/acme/web/pull_requests/10/assessments", text: /Ask Jev/
    assert_select "form.ask-jev", 2
  end

  test "a pull request too big for Jev opens on GitHub instead of asking again, until it changes" do
    users(:one).oversized_pull_requests.create!(repo_full_name: "acme/web", pr_number: 7, head_sha: "sha-7")
    users(:one).oversized_pull_requests.create!(repo_full_name: "acme/web", pr_number: 8, head_sha: "old-sha")
    stub_github_pull_requests([ 7, 8 ].map { |n| pull_request_node(number: n, title: "PR #{n}", head_sha: "sha-#{n}") })

    get repository_pull_requests_path(owner: "acme", repo: "web")

    assert_select "a[href=?][target=_blank]", "https://github.com/acme/web/pull/7", text: /Too big for Jev.*Too big/m
    assert_select "form.ask-jev[action=?]", "/repositories/acme/web/pull_requests/7/assessments", 0
    assert_select "form.ask-jev[action=?] button", "/repositories/acme/web/pull_requests/8/assessments", text: /Ask Jev/
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

  private
    def assess(number, choice:, head_sha:)
      users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: number, pr_title: "PR #{number}",
                                         pr_url: "https://github.com/acme/web/pull/#{number}", choice: choice, head_sha: head_sha)
    end
end
