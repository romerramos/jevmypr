require "application_system_test_case"

class FileReviewsTest < ApplicationSystemTestCase
  test "the verdict page shows Jev's verdict for each file at phone and desktop widths" do
    user = users(:one)
    file = ->(name, extra) { { "filename" => name, "status" => "modified", "additions" => 12, "deletions" => 3 }.merge(extra) }
    files = [
      file.("app/models/account.rb", "choice" => "yes", "probabilities" => { "yes" => 0.8, "llm_enough" => 0.15, "no" => 0.05 }),
      file.("test/models/account_test.rb", "choice" => "llm_enough", "probabilities" => { "llm_enough" => 0.7 }),
      file.("app/views/accounts/really/deeply/nested/directory/structure/show.html.erb", "choice" => "llm_enough", "probabilities" => {}),
      file.("assets/logo.png", "skipped" => "no_patch")
    ]
    files.unshift(file.("docs/usage.md", "choice" => "no", "probabilities" => { "no" => 0.9 }))
    assessment = user.pr_assessments.create!(repo_full_name: "acme/web", pr_number: 7, pr_title: "Update account flow",
      pr_url: "https://github.com/acme/web/pull/7", choice: "yes", head_sha: "sha-7", changed_files: 5, additions: 60, deletions: 15,
      files: files, probabilities: { "yes" => 0.7, "llm_enough" => 0.2, "no" => 0.1 }, confidence: 0.6, jev_model: "jev-1.13.0")
    stub_github_repositories("acme/web")

    sign_in_with_github user
    visit assessment_path(assessment)

    assert_selector "[aria-label='Files by verdict']", text: /1\s+Human review/
    assert_selector "[aria-label='Files by verdict']", text: /2\s+LLM review/
    assert_selector "li", text: /account\.rb.*Human review/m
    assert_selector "li [title='Human review 80% · LLM review 15% · No review 5%']"
    assert_selector "li", text: /logo\.png.*No diff/m
    assert_no_button "Check every file"
    assert_equal %w[account.rb account_test.rb show.html.erb usage.md logo.png],
                 all("section[aria-labelledby=changed-files] li code").map { |code| code.text.split("/").last }

    [ [ 390, 844 ], [ 1400, 1000 ] ].each do |width, height|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: height, deviceScaleFactor: 1, mobile: width < 500)
      [ "triage", "triage-night" ].each do |theme|
        page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
        assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
        page.execute_script("document.getElementById('changed-files').scrollIntoView({ block: 'start' })")
        page.save_screenshot(Rails.root.join("tmp", "file-reviews-#{width}-#{theme}.png"))
      end
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.manage.window.resize_to(1400, 1000)
  end
end
