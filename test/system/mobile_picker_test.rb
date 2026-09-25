require "application_system_test_case"

class MobilePickerTest < ApplicationSystemTestCase
  setup { page.driver.browser.manage.window.resize_to(480, 900) }
  teardown { page.driver.browser.manage.window.resize_to(1400, 1000) }

  test "phones show one pane at a time and come back to the repository list" do
    repos = (1..40).map { |i| format("acme/service-%02d", i) }
    stub_github_repositories(*repos)
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect") ])

    sign_in_with_github users(:one)
    assert_selector "#repositories a[data-repo]", count: 40
    assert_no_selector "#pull_requests", visible: true

    target = find("a[data-repo='acme/service-35']")
    target.scroll_to(target)
    scroll_before = page.evaluate_script("window.scrollY")
    assert_operator scroll_before, :>, 300

    target.click
    assert_selector "#pull_requests button", text: "Fix login redirect"
    assert_no_selector "#repositories", visible: true
    panes_top = page.evaluate_script("document.querySelector('[data-picker-target=panes]').getBoundingClientRect().top")
    assert_in_delta 0, panes_top, 12, "the pull request pane should be scrolled to the top of the screen"
    assert_current_path root_path(repo: "acme/service-35")

    click_on "Repositories"
    assert_selector "a[data-repo='acme/service-35'][aria-current]", visible: true
    assert_no_selector "#pull_requests", visible: true
    assert_in_delta scroll_before, page.evaluate_script("window.scrollY"), 5
    assert_current_path root_path
  end

  test "coming back from a verdict opens the pull request list directly" do
    stub_github_repositories("acme/web")
    stub_github_pull_requests([ pull_request_node(number: 7, title: "Fix login redirect") ])
    sign_in_with_github users(:one)

    visit root_path(repo: "acme/web")

    assert_selector "#pull_requests button", text: "Fix login redirect"
    assert_selector "button", text: "Repositories"
    assert_no_selector "#repositories", visible: true
  end
end
