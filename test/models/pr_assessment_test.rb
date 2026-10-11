require "test_helper"

class PrAssessmentTest < ActiveSupport::TestCase
  test "only accepts Jev's three options" do
    assessment = users(:one).pr_assessments.new(repo_full_name: "acme/web", pr_number: 1, pr_title: "x", pr_url: "https://github.com/acme/web/pull/1", choice: "maybe")

    assert_not assessment.valid?
    assert assessment.errors.of_kind?(:choice, :inclusion)
  end

  test "ranked probabilities follow the tag order and default missing options to zero" do
    assessment = PrAssessment.new(choice: "no", probabilities: { "no" => 0.9, "yes" => 0.1 })

    assert_equal [ [ "yes", 0.1 ], [ "llm_enough", 0.0 ], [ "no", 0.9 ] ], assessment.ranked_probabilities.map { |key, _, p| [ key, p ] }
  end

  test "only links to github.com" do
    assessment = users(:one).pr_assessments.new(repo_full_name: "acme/web", pr_number: 1, pr_title: "x", pr_url: "javascript:alert(1)", choice: "no")

    assert_not assessment.valid?
    assert assessment.errors.of_kind?(:pr_url, :invalid)
  end

  test "search matches every term against title, repository or PR number" do
    user = users(:one)
    a = user.pr_assessments.create!(repo_full_name: "acme/web", pr_number: 42, pr_title: "Fix 100% CPU", pr_url: "https://github.com/acme/web/pull/42", choice: "no")
    user.pr_assessments.create!(repo_full_name: "acme/api", pr_number: 7, pr_title: "Fix login", pr_url: "https://github.com/acme/api/pull/7", choice: "no")

    assert_equal [ a ], user.pr_assessments.search("fix web").to_a
    assert_equal [ a ], user.pr_assessments.search("#42").to_a
    assert_equal [ a ], user.pr_assessments.search("100%").to_a
    assert_empty user.pr_assessments.search("Fix_login").to_a # "_" is literal, not "any character"
    assert_equal 2, user.pr_assessments.search("").count
  end

  test "a verdict is current only for its exact known commit" do
    pr = Data.define(:head_sha).new(head_sha: "abc")

    assert PrAssessment.new(head_sha: "abc").current_for?(pr)
    assert_not PrAssessment.new(head_sha: "old").current_for?(pr)
    assert_not PrAssessment.new(head_sha: nil).current_for?(pr)
  end

  test "files_by_verdict puts human review files first, then LLM, then no review, then files without a verdict" do
    files = [ { "filename" => "docs.md", "choice" => "no" }, { "filename" => "logo.png", "skipped" => "no_patch" },
              { "filename" => "auth.rb", "choice" => "yes" }, { "filename" => "a_test.rb", "choice" => "llm_enough" },
              { "filename" => "b_test.rb", "choice" => "llm_enough" }, { "filename" => "pay.rb", "choice" => "yes" } ]

    assert_equal %w[auth.rb pay.rb a_test.rb b_test.rb docs.md logo.png],
                 PrAssessment.new(files: files).files_by_verdict.map { |f| f["filename"] }
  end

  test "shared snapshots require a known head but not a surviving requester" do
    assessment = repositories(:web).pr_assessments.new(repo_full_name: "acme/web", pr_number: 7, pr_title: "Docs",
      pr_url: "https://github.com/acme/web/pull/7", choice: "no")

    assert_not assessment.valid?
    assert assessment.errors.of_kind?(:head_sha, :blank)
    assessment.head_sha = "abc"
    assert assessment.valid?
  end

  test "API verdicts have no pull request or owner, and get a token and an expiry" do
    api = api_verdict

    assert api.valid?, api.errors.full_messages.inspect
    api.save!
    assert_match(/\A[1-9A-HJ-NP-Za-km-z]{24}\z/, api.token)
    assert_not_equal api.token, api_verdict(diff_sha256: "other").tap(&:save!).token

    assert_not api_verdict(user: users(:one)).valid?
    assert_not api_verdict(repository: Repository.create!(github_id: 991, full_name: "acme/web")).valid?
    assert_not api_verdict(expires_at: nil).valid?
    assert_not api_verdict(diff_sha256: nil).valid?
  end

  test "web verdicts never get a token" do
    web = users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 1, pr_title: "x", pr_url: "https://github.com/acme/web/pull/1", choice: "no")

    assert_equal "web", web.source
    assert_nil web.token
  end

  test "the database refuses API verdicts with an owner and web verdicts without a pull request" do
    api = api_verdict.tap(&:save!)
    assert_raises(ActiveRecord::StatementInvalid) { api.update_columns(user_id: users(:one).id) }

    web = users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 1, pr_title: "x", pr_url: "https://github.com/acme/web/pull/1", choice: "no")
    assert_raises(ActiveRecord::StatementInvalid) { web.update_columns(pr_url: nil) }
  end

  test "deletes only expired API verdicts" do
    expired = api_verdict(expires_at: 1.minute.ago).tap(&:save!)
    live = api_verdict(diff_sha256: "live").tap(&:save!)
    web = users(:one).pr_assessments.create!(repo_full_name: "acme/web", pr_number: 1, pr_title: "x", pr_url: "https://github.com/acme/web/pull/1", choice: "no")

    assert_equal 1, PrAssessment.delete_expired
    assert_not PrAssessment.exists?(expired.id)
    assert_equal [ live ], PrAssessment.api.live.to_a
    assert PrAssessment.exists?(web.id)
  end

  test "lists and access checks never include API verdicts" do
    user = users(:one)
    repo = Repository.create!(github_id: 4242, full_name: "acme/web")
    shared = repo.pr_assessments.create!(repo_full_name: "acme/web", pr_number: 1, pr_title: "x", head_sha: "abc",
                                         pr_url: "https://github.com/acme/web/pull/1", choice: "no")
    api = api_verdict.tap(&:save!)
    github = Object.new
    def github.repositories(**) = [ Github::Client::Repository.new(github_id: 4242, full_name: "acme/web", name: "web", owner: "acme",
                                                                   private: false, description: nil, pushed_at: nil) ]

    assert_equal [ shared ], PrAssessment.accessible_to(user: user, github: github).to_a
    assert_raises(ActiveRecord::RecordNotFound) { api.verify_access!(user: user, github: github) }
  end

  private
    def api_verdict(**attributes)
      PrAssessment.new({ source: "api", diff_sha256: "abc123", expires_at: PrAssessment::API_LIFETIME.from_now,
                         pr_title: "Fix typo", choice: "no" }.merge(attributes))
    end
end
