require "test_helper"

class DiffPayloadTest < ActiveSupport::TestCase
  def payload(**attributes)
    DiffPayload.new({ title: "Add refunds", files: [ { filename: "app/refund.rb", status: "added", patch: "@@ -0,0 +1,2 @@\n+a\n+b" } ] }.merge(attributes))
  end

  test "builds the pull request and file objects Github::Client returns" do
    diff = DiffPayload.new("repository" => "acme/web", "title" => "Add refunds", "description" => "Refund flow", "base_branch" => "main",
                           "head_branch" => "refunds", "files" => [
                             { "filename" => "app/refund.rb", "status" => "added", "patch" => "@@ -0,0 +1,2 @@\n+a\n+b" },
                             { "filename" => "lib/new.rb", "previous_filename" => "lib/old.rb", "status" => "renamed",
                               "additions" => 4, "deletions" => 3, "patch" => "@@ -1 +1 @@\n-old\n+new" },
                             { "filename" => "logo.png", "patch" => "" }
                           ])

    assert diff.valid?
    assert_equal "acme/web", diff.repository
    assert_equal Github::Client::FileChange.new(filename: "app/refund.rb", previous_filename: nil, status: "added",
                                                additions: 2, deletions: 0, patch: "@@ -0,0 +1,2 @@\n+a\n+b"), diff.files.first
    assert_equal [ "lib/old.rb", 4, 3 ], diff.files.second.deconstruct_keys(nil).values_at(:previous_filename, :additions, :deletions)
    assert_equal [ "modified", nil, 0 ], [ diff.files.third.status, diff.files.third.patch, diff.files.third.additions ]

    pr = diff.pull_request
    assert_kind_of Github::Client::PullRequest, pr
    assert_nil pr.number
    assert_equal [ "Add refunds", "Refund flow", "main", "refunds" ], [ pr.title, pr.body, pr.base_ref, pr.head_ref ]
    assert_equal [ 6, 3, 3 ], [ pr.additions, pr.deletions, pr.changed_files ]
    assert_equal diff.sha256, pr.head_sha
  end

  test "a missing title gets a placeholder" do
    assert_equal DiffPayload::DEFAULT_TITLE, payload(title: " ").pull_request.title
  end

  test "the hash depends on the change, not on its title" do
    assert_equal payload.sha256, payload(title: "Other").sha256
    assert_not_equal payload.sha256, payload(files: [ { filename: "app/refund.rb", status: "added", patch: "@@ -0,0 +1 @@\n+c" } ]).sha256
  end

  test "needs a list of files" do
    [ nil, [], "a diff", [ "a.rb" ], { filename: "a.rb" } ].each do |files|
      assert_not payload(files: files).valid?, "files: #{files.inspect}"
    end
    assert_not payload(files: Array.new(DiffPayload::MAX_FILES + 1) { |i| { filename: "f#{i}.rb" } }).valid?
  end

  test "checks every file" do
    invalid = [ { filename: "" }, { filename: 1 }, { filename: "a" * (DiffPayload::MAX_FILENAME_LENGTH + 1) },
                { filename: "a.rb", status: "deleted" }, { filename: "a.rb", additions: -1 }, { filename: "a.rb", deletions: "2" },
                { filename: "a.rb", patch: [ "+a" ] }, { filename: "a.rb", patch: "+\xff".b.force_encoding("UTF-8") },
                { filename: "a.rb", previous_filename: { name: "b.rb" } } ]

    invalid.each do |file|
      diff = payload(files: [ { filename: "ok.rb" }, file ])
      assert_not diff.valid?, "file: #{file.inspect}"
      assert diff.errors[:files].sole.start_with?("files[1]."), diff.errors.full_messages.inspect
    end
  end

  test "checks the text fields" do
    assert_not payload(title: "a" * (DiffPayload::MAX_TITLE_LENGTH + 1)).valid?
    assert_not payload(description: "a" * (DiffPayload::MAX_DESCRIPTION_LENGTH + 1)).valid?
    assert_not payload(repository: { name: "web" }).valid?
    assert_not payload(head_branch: [ "main" ]).valid?

    diff = payload(title: "a" * (DiffPayload::MAX_TITLE_LENGTH + 1), files: [ { filename: "a.rb", status: "deleted" } ])
    assert_not diff.valid?
    assert_equal [ "Title is too long (at most 300 characters)", "files[0].status must be one of #{DiffPayload::STATUSES.to_sentence(last_word_connector: ' or ')}" ],
                 diff.error_messages
  end

  test "refuses patches far beyond what Jev reads" do
    half = DiffPayload::MAX_PATCH_BYTES / 2
    assert payload(files: [ { filename: "a.rb", patch: "+" * half }, { filename: "b.rb", patch: "+" * half } ]).valid?

    diff = payload(files: [ { filename: "a.rb", patch: "+" * half }, { filename: "b.rb", patch: "+" * (half + 1) } ])
    assert_not diff.valid?
    assert_match "too big", diff.errors[:files].sole
  end

  test "reads permitted controller params" do
    params = ActionController::Parameters.new(diff: { title: "Add refunds", files: [ { filename: "a.rb", patch: "+a" } ], extra: "x" })

    diff = DiffPayload.new(params.expect(diff: DiffPayload::PERMITTED))

    assert diff.valid?
    assert_equal [ "a.rb", 1 ], [ diff.files.sole.filename, diff.files.sole.additions ]
  end
end
