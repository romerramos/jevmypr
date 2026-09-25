require "test_helper"

class PullRequestsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "lists open pull requests as Ask Jev buttons that post to assessments" do
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect"), pull_request_node(number: 9, title: "Bump rails", draft: true) ])

    get pull_requests_path(repo: "acme/web")

    assert_response :success
    assert_select "turbo-frame#pull_requests turbo-frame#pull_request_results"
    assert_select "form[action=?][data-turbo-frame='_top']", assessments_path, 2
    assert_select "form input[name=number][value='7']"
    assert_select "button", text: /Fix login redirect/
    assert_select ".badge", "Draft"
  end

  test "shows the previous verdict for pull requests already assessed" do
    users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 7, pr_title: "Fix login redirect", pr_url: "https://github.com/acme/web/pull/7", choice: "llm_enough")
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect") ])

    get pull_requests_path(repo: "acme/web")

    assert_select "button", text: /Tagged llm review/
    assert_select "button", text: /Ask again/
  end

  test "search results render into the inner frame" do
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect") ])

    get pull_requests_path(repo: "acme/web", q: "payments"), headers: { "Turbo-Frame" => "pull_request_results" }

    assert_select "turbo-frame#pull_request_results", text: /No open pull requests match “payments”/
  end

  test "GitHub errors render inside the requesting frame" do
    stub_request(:post, "#{ApiStubs::GITHUB}/graphql").to_return(json_response({}, status: 500))

    get pull_requests_path(repo: "acme/web"), headers: { "Turbo-Frame" => "pull_requests" }

    assert_select "turbo-frame#pull_requests [role=alert]", text: /GitHub returned HTTP 500/
  end
end
