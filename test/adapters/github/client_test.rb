require "test_helper"

class Github::ClientTest < ActiveSupport::TestCase
  API = Github::Client::API_URL

  setup do
    @client = Github::Client.new("gho_token")
  end

  test "repositories follows pagination and filters by every search term" do
    stub_request(:get, "#{API}/user/repos")
      .with(query: hash_including(per_page: "100"), headers: { "Authorization" => "Bearer gho_token" })
      .to_return(json_response([ repo_json("acme/billing-api") ], headers: { "Link" => %(<#{API}/user/repos?page=2>; rel="next") }))
    stub_request(:get, "#{API}/user/repos?page=2")
      .to_return(json_response([ repo_json("acme/web"), repo_json("romer/billing-ui") ]))

    assert_equal %w[acme/billing-api acme/web romer/billing-ui], @client.repositories.map(&:full_name)
    assert_equal %w[acme/billing-api], @client.repositories(query: "ACME bill").map(&:full_name)
  end

  test "pull_requests uses GraphQL and returns diffstats" do
    stub_request(:post, "#{API}/graphql")
      .with(body: hash_including(variables: { owner: "acme", name: "web" }))
      .to_return(json_response({ data: { repository: { pullRequests: { nodes: [
        { number: 7, title: "Fix login redirect", body: "", url: "https://github.com/acme/web/pull/7", isDraft: false,
          updatedAt: "2026-09-20T10:00:00Z", additions: 12, deletions: 3, changedFiles: 2,
          baseRefName: "main", headRefName: "fix-login", headRefOid: "f00d", author: { login: "ana", avatarUrl: "https://a/ana" } },
        { number: 9, title: "Bump rails", body: "", url: "https://github.com/acme/web/pull/9", isDraft: true,
          updatedAt: "2026-09-21T10:00:00Z", additions: 1, deletions: 1, changedFiles: 1,
          baseRefName: "main", headRefName: "bump", author: nil }
      ] } } } }))

    pulls = @client.pull_requests("acme/web")
    assert_equal [ 7, 9 ], pulls.map(&:number)
    assert_equal [ 12, 3 ], [ pulls.first.additions, pulls.first.deletions ]
    assert_equal "f00d", pulls.first.head_sha
    assert_nil pulls.last.author_login

    assert_equal [ 9 ], @client.pull_requests("acme/web", query: "#9").map(&:number)
    assert_equal [ 7 ], @client.pull_requests("acme/web", query: "ana").map(&:number)
  end

  test "pull_requests raises NotFound for an unknown repository" do
    stub_request(:post, "#{API}/graphql")
      .to_return(json_response({ data: { repository: nil }, errors: [ { type: "NOT_FOUND", message: "Could not resolve to a Repository" } ] }))

    assert_raises(Github::Client::NotFound) { @client.pull_requests("acme/missing") }
  end

  test "pull_request and files with their patches" do
    stub_request(:get, "#{API}/repos/acme/web/pulls/7")
      .with(headers: { "Accept" => "application/vnd.github+json" })
      .to_return(json_response({ number: 7, title: "Fix login redirect", body: "Details", html_url: "https://github.com/acme/web/pull/7",
                                 draft: false, user: { login: "ana", avatar_url: "https://a/ana" }, base: { ref: "main" },
                                 head: { ref: "fix-login", sha: "f00d" }, additions: 12, deletions: 3, changed_files: 2, updated_at: "2026-09-20T10:00:00Z" }))
    stub_request(:get, "#{API}/repos/acme/web/pulls/7/files").with(query: hash_including({}))
      .to_return(json_response([ { filename: "app/login.rb", previous_filename: "app/signin.rb", status: "renamed",
                                   additions: 12, deletions: 3, patch: "+new" } ]))

    pr = @client.pull_request("acme/web", "7")
    assert_equal [ "ana", "main", "fix-login", "f00d" ], [ pr.author_login, pr.base_ref, pr.head_ref, pr.head_sha ]
    file = @client.pull_request_files("acme/web", 7).sole
    assert_equal [ "app/login.rb", "app/signin.rb", "+new" ], [ file.filename, file.previous_filename, file.patch ]
  end

  test "files paginate beyond the repository limit" do
    6.times do |i|
      page = i + 1
      query = page == 1 ? { per_page: "100" } : { page: page.to_s }
      headers = page < 6 ? { "Link" => %(<#{API}/repos/acme/web/pulls/7/files?page=#{page + 1}>; rel="next") } : {}
      stub_request(:get, "#{API}/repos/acme/web/pulls/7/files").with(query: query)
        .to_return(json_response([ { filename: "file#{page}.rb", status: "modified", patch: "+new" } ], headers: headers))
    end

    assert_equal 6, @client.pull_request_files("acme/web", 7).size
  end

  test "rejects repository names and numbers that aren't owner/name and integers" do
    assert_raises(Github::Client::NotFound) { @client.pull_request("../user", 1) }
    assert_raises(Github::Client::NotFound) { @client.pull_request("acme/..", 1) }
    assert_raises(Github::Client::NotFound) { @client.pull_request("acme/web", "7/files") }
  end

  test "maps HTTP errors" do
    stub_request(:get, "#{API}/repos/acme/web/pulls/1").to_return(json_response({}, status: 401))
    assert_raises(Github::Client::Unauthorized) { @client.pull_request("acme/web", 1) }

    stub_request(:get, "#{API}/repos/acme/web/pulls/2").to_return(json_response({}, status: 404))
    assert_raises(Github::Client::NotFound) { @client.pull_request("acme/web", 2) }

    stub_request(:get, "#{API}/repos/acme/web/pulls/3").to_return(json_response({}, status: 403, headers: { "X-RateLimit-Remaining" => "0" }))
    error = assert_raises(Github::Client::Error) { @client.pull_request("acme/web", 3) }
    assert_match "rate limit", error.message
  end

  private
    def repo_json(full_name)
      owner, name = full_name.split("/")
      { full_name: full_name, name: name, owner: { login: owner }, private: false, description: nil, pushed_at: "2026-09-20T10:00:00Z" }
    end
end
