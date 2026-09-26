require "application_system_test_case"

class TriageFlowTest < ApplicationSystemTestCase
  test "search a repository, pick a pull request, get the verdict and go back with Esc" do
    stub_github_repositories("acme/web", "acme/billing")
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect"), pull_request_node(number: 9, title: "Bump rails") ])
    stub_github_pull_request(repo: "acme/web", number: 7, title: "Fix login redirect")
    stub_jev(choice: "llm_enough", probabilities: { "yes" => 0.2, "llm_enough" => 0.7, "no" => 0.1 }, confidence: 0.64)

    sign_in_with_github users(:one)
    assert_current_path repositories_path
    assert_selector "#repositories a[data-picker-item]", count: 2

    fill_in "Search repositories", with: "web"
    assert_selector "#repositories a[data-picker-item]", count: 1

    click_on "acme/web"
    assert_current_path "/repositories/acme/web/pull_requests"
    assert_selector "#pull_request_results button", text: "Fix login redirect"
    assert_selector "#repository_sidebar a[aria-current=page]", text: "acme/web"
    assert_field "Search repositories", with: "web" # the sidebar is kept across the visit

    fill_in "Search pull requests", with: "bump"
    assert_no_selector "#pull_request_results button", text: "Fix login redirect"
    assert_current_path "/repositories/acme/web/pull_requests" # the search stays in the box, not the URL
    fill_in "Search pull requests", with: ""
    assert_selector "#pull_request_results button", text: "Fix login redirect"
    click_on "Fix login redirect"

    assert_selector "h1", text: "An LLM review is enough."
    assert_selector ".triage-tag__strip--green.is-torn"
    assert_text "70%"

    find("body").send_keys(:escape)
    assert_current_path "/repositories/acme/web/pull_requests"

    # Same commit as before: the row reopens the saved verdict instead of asking Jev again.
    click_on "Fix login redirect"
    assert_selector "h1", text: "An LLM review is enough."
    assert_requested :post, Jev::Client::URL, times: 1
  end

  test "slash focuses the repository search" do
    stub_github_repositories("acme/web")
    sign_in_with_github users(:one)
    assert_selector "#repositories a[data-picker-item]"

    find("body").send_keys("/")

    assert_equal "Search repositories", page.evaluate_script("document.activeElement.getAttribute('aria-label')")
  end

  test "pin a repository to the top and unpin it" do
    stub_github_repositories("acme/alpha", "acme/beta", "acme/gamma")
    sign_in_with_github users(:one)
    assert_equal %w[alpha beta gamma], repo_names

    find("#repositories li", text: "acme/gamma").hover # the pin appears on hover for mouse users
    click_on "Pin acme/gamma"
    assert_selector "button[aria-label='Unpin acme/gamma'][aria-pressed=true]"
    assert_equal %w[gamma alpha beta], repo_names
    assert_selector "#repositories li[role=separator]"

    click_on "Unpin acme/gamma"
    assert_selector "button[aria-label='Pin acme/gamma'][aria-pressed=false]", visible: :all
    assert_equal %w[alpha beta gamma], repo_names
  end

  private
    def repo_names
      all("#repositories a[data-picker-item]").map { |a| URI(a[:href]).path.split("/")[3] }
    end
end
