require "test_helper"

class VerdictsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @verdict = PrAssessment.create!(source: "api", diff_sha256: "abc123", expires_at: 10.days.from_now, pr_title: "Add refund flow",
                                    choice: "yes", probabilities: { "yes" => 0.8, "llm_enough" => 0.15, "no" => 0.05 }, confidence: 0.7,
                                    jev_model: "jev-1.13.0", additions: 12, deletions: 3, changed_files: 2,
                                    files: [ { "filename" => "app/refund.rb", "status" => "added", "additions" => 12, "deletions" => 0, "choice" => "yes" },
                                             { "filename" => "logo.png", "status" => "added", "additions" => 0, "deletions" => 0, "skipped" => "no_patch" } ])
  end

  test "anyone with the link sees the verdict, without signing in" do
    get verdict_path(@verdict.token)

    assert_response :success
    assert_nil response.cookies["session_id"]
    assert_select "h1", PrAssessment::VERDICTS["yes"][:headline]
    assert_match "Add refund flow", response.body
    assert_select "code", "app/refund.rb"
    assert_select "code", "logo.png"
    assert_select "[aria-label='Verdict privacy']", text: /Anyone with this link can see this verdict until #{Regexp.escape(@verdict.expires_at.to_date.to_fs(:long))}/
    assert_select "a[href=?]", new_session_path
    # Nothing that needs an account: no asking again, voting or GitHub link.
    assert_select "form", count: 0
    assert_select "a[href*='/pull/']", count: 0
  end

  test "keeps the link out of search engines, caches and referrers" do
    get verdict_path(@verdict.token)

    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_select "meta[name=robots][content=?]", "noindex, nofollow"
  end

  test "a signed-in visitor sees it too" do
    sign_in_as users(:one)

    get verdict_path(@verdict.token)

    assert_response :success
    assert_select "a[href=?]", repositories_path, text: /Triage your own pull requests/
  end

  test "wrong, malformed and expired links are 404s, and web verdicts have no link" do
    web = users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 1, pr_title: "x", pr_url: "https://github.com/acme/web/pull/1", choice: "no")
    web.update_columns(token: "W" * 24) # even if a web verdict somehow had a token

    [ "1" * 24, "short", "#{@verdict.token}x", "W" * 24 ].each do |token|
      get verdict_path(token)
      assert_response :not_found, token
    end

    @verdict.update!(expires_at: 1.minute.ago)
    get verdict_path(@verdict.token)
    assert_response :not_found
  end
end
