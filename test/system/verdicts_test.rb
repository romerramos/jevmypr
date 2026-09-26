require "application_system_test_case"

class VerdictsTest < ApplicationSystemTestCase
  test "search, filter by verdict and page through verdicts" do
    user = users(:one)
    22.times do |i|
      user.pr_assessments.create!(repo_full_name: "acme/web", pr_number: i + 1, pr_title: "Routine change #{i + 1}",
                                  pr_url: "https://github.com/acme/web/pull/#{i + 1}", choice: "no", created_at: i.minutes.ago)
    end
    user.pr_assessments.create!(repo_full_name: "acme/vault", pr_number: 99, pr_title: "Rotate API keys",
                                pr_url: "https://github.com/acme/vault/pull/99", choice: "yes", created_at: 1.day.ago)
    stub_github_repositories("acme/web")
    sign_in_with_github user

    click_on "Verdicts"
    assert_selector "h1", text: "Your verdicts"
    assert_selector "#verdicts .list-row", count: 20
    assert_text "1–20 of 23"

    click_on "Older"
    assert_selector "#verdicts .list-row", count: 3
    assert_text "21–23 of 23"

    find("label", text: "Human review").click
    assert_selector "#verdicts .list-row", count: 1, text: "Rotate API keys"

    find("label", text: /\AAll/).click
    fill_in "Search verdicts", with: "#7"
    assert_selector "#verdicts .list-row", count: 1, text: "Routine change 7"
  end
end
