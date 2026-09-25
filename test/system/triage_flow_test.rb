require "application_system_test_case"

class TriageFlowTest < ApplicationSystemTestCase
  test "search a repository, pick a pull request, get the verdict and go back with Esc" do
    stub_github_repositories("acme/web", "acme/billing")
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect"), pull_request_node(number: 9, title: "Bump rails") ])
    stub_github_pull_request(repo: "acme/web", number: 7, title: "Fix login redirect")
    stub_jev(choice: "llm_enough", probabilities: { "yes" => 0.2, "llm_enough" => 0.7, "no" => 0.1 }, confidence: 0.64)

    sign_in_with_github users(:one)
    assert_selector "h1", text: "Which PR should Jev triage?"
    assert_selector "#repositories a[data-repo]", count: 2

    fill_in "Search repositories", with: "web"
    assert_selector "#repositories a[data-repo]", count: 1

    click_on "acme/web"
    assert_selector "#pull_requests button", text: "Fix login redirect"
    assert_selector "a[data-repo='acme/web'][aria-current]"
    assert_current_path root_path(repo: "acme/web")

    fill_in "Search pull requests", with: "bump"
    assert_no_selector "#pull_request_results button", text: "Fix login redirect"
    fill_in "Search pull requests", with: ""
    click_on "Fix login redirect"

    assert_selector "h1", text: "An LLM review is enough."
    assert_selector ".triage-tag__strip--green.is-torn"
    assert_text "70%"

    find("body").send_keys(:escape)
    assert_selector "h1", text: "Which PR should Jev triage?"
    assert_current_path root_path(repo: "acme/web")
    assert_selector "#pull_requests button", text: /Tagged llm review/
  end

  test "slash focuses the repository search" do
    stub_github_repositories("acme/web")
    sign_in_with_github users(:one)
    assert_selector "#repositories a[data-repo]"

    find("body").send_keys("/")

    assert_equal "q", page.evaluate_script("document.activeElement.name")
    assert page.evaluate_script("document.activeElement.closest('form').action").end_with?(repositories_path)
  end
end
