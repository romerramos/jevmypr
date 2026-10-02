require "application_system_test_case"

class FeedbackTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @assessment = @user.pr_assessments.create!(repo_full_name: "acme/web", pr_number: 7, pr_title: "Fix a typo in the README",
      pr_url: "https://github.com/acme/web/pull/7", choice: "no", changed_files: 1, additions: 1, deletions: 1,
      probabilities: { "yes" => 0.04, "llm_enough" => 0.11, "no" => 0.85 }, confidence: 0.8, jev_model: "jev-1.13.0")
    stub_github_repositories("acme/web")
    sign_in_with_github @user
  end

  test "agree, change your mind, then disagree with a reason" do
    visit assessment_path(@assessment)
    within("#feedback") { click_on "Agree" }
    assert_selector "#feedback", text: "You agreed with Jev."

    within("#feedback") { click_on "Change vote" }
    within("#feedback") { click_on "Disagree" }
    within("#feedback") { find("label", text: "Human review").click }
    fill_in "feedback[reason]", with: "It also changes the payments webhook."
    screenshots("feedback-form")
    within("#feedback") { click_on "Save vote" }

    assert_selector "#feedback", text: "You said this needed a human review."
    assert_selector "#feedback blockquote", text: "It also changes the payments webhook."
    assert_equal "yes", @assessment.reload.feedback_choice
    screenshots("feedback-saved")

    click_on "Verdicts"
    assert_text "You agreed with 0 of 1 verdict you rated."
    assert_text "1 needed more review than Jev said."
  end

  private
    def screenshots(name)
      [ [ 390, 844 ], [ 1400, 1000 ] ].each do |width, height|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
          width: width, height: height, deviceScaleFactor: 1, mobile: width < 500)
        [ "triage", "triage-night" ].each do |theme|
          page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
          assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
          page.execute_script("document.getElementById('feedback').scrollIntoView({ block: 'center' })")
          page.save_screenshot(Rails.root.join("tmp", "#{name}-#{width}-#{theme}.png"))
        end
      end
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
      page.driver.browser.manage.window.resize_to(1400, 1000)
    end
end
