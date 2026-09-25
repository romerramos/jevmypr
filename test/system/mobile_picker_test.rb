require "application_system_test_case"

class MobilePickerTest < ApplicationSystemTestCase
  setup { page.driver.browser.manage.window.resize_to(480, 900) }
  teardown { page.driver.browser.manage.window.resize_to(1400, 1000) }

  test "phones get separate pages, and the back gesture returns to the same spot" do
    stub_github_repositories(*(1..40).map { |i| format("acme/service-%02d", i) })
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect") ])

    sign_in_with_github users(:one)
    assert_selector "#repositories a[data-picker-item]", count: 40
    assert_no_text "Choose a repository to see its open pull requests." # the empty right pane is desktop-only

    target = find("a[href='/repositories/acme/service-35/pull_requests']")
    target.scroll_to(target)
    scroll_before = page.evaluate_script("window.scrollY")
    assert_operator scroll_before, :>, 300

    target.click
    assert_current_path "/repositories/acme/service-35/pull_requests"
    assert_selector "#pull_request_results button", text: "Fix login redirect"
    assert_no_selector "#repository_sidebar", visible: true
    assert_operator page.evaluate_script("window.scrollY"), :<, 50

    page.go_back
    assert_current_path repositories_path
    assert_selector "#repository_sidebar", visible: true
    assert_in_delta scroll_before, page.evaluate_script("window.scrollY"), 5
  end

  test "the Repositories link on a pull request page goes to the list" do
    stub_github_repositories("acme/web")
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect") ])
    sign_in_with_github users(:one)

    visit "/repositories/acme/web/pull_requests"
    assert_selector "#pull_request_results button", text: "Fix login redirect"

    click_on "All repositories"
    assert_current_path repositories_path
    assert_selector "#repositories a[data-picker-item]", text: "acme/web"
  end
end
