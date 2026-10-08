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

  test "repository identity lookups are uncached and use the viewer's token" do
    stub_request(:get, "#{API}/repos/acme/web")
      .with(headers: { "Authorization" => "Bearer gho_token" })
      .to_return(json_response(repo_json("acme/web", github_id: 42)))
    stub_request(:get, "#{API}/repositories/42")
      .with(headers: { "Authorization" => "Bearer gho_token" })
      .to_return(json_response(repo_json("acme/renamed", github_id: 42)))

    assert_equal 42, @client.repository("acme/web").github_id
    2.times { assert_equal "acme/renamed", @client.repository(42).full_name }
    assert_requested :get, "#{API}/repositories/42", times: 2
  end

  test "a fresh discovery list bypasses cached repository memberships" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    stub_request(:get, "#{API}/user/repos").with(query: hash_including({}))
      .to_return(json_response([ repo_json("acme/web") ]), json_response([]))

    assert_equal [ "acme/web" ], @client.repositories.map(&:full_name)
    assert_equal [ "acme/web" ], @client.repositories.map(&:full_name)
    assert_empty @client.repositories(fresh: true)
    assert_requested :get, "#{API}/user/repos", query: hash_including({}), times: 2
  ensure
    Rails.cache = original_cache
  end

  test "a cached repository lookup remembers hits and misses until refreshed" do
    with_memory_cache do
      stub_request(:get, "#{API}/repos/acme/web").to_return(json_response(repo_json("acme/web", github_id: 42)))
      stub_request(:get, "#{API}/repos/acme/gone").to_return(json_response({}, status: 404))

      2.times do
        assert_equal 42, @client.repository("acme/web", cached: true).github_id
        assert_raises(Github::Client::NotFound) { @client.repository("acme/gone", cached: true) }
      end
      @client.repository("acme/web", cached: true, fresh: true)
      assert_requested :get, "#{API}/repos/acme/web", times: 2
      assert_requested :get, "#{API}/repos/acme/gone", times: 1
    end
  end

  test "missing, invalid or mismatched GitHub IDs do not authorize a repository" do
    [ nil, 0, -42, "42" ].each do |github_id|
      stub_request(:get, "#{API}/repos/acme/web").to_return(json_response(repo_json("acme/web", github_id: github_id)))
      assert_raises(Github::Client::Error) { @client.repository("acme/web") }
    end
    stub_request(:get, "#{API}/repositories/42").to_return(json_response(repo_json("acme/web", github_id: 99)))
    assert_raises(Github::Client::NotFound) { @client.repository(42) }
    assert_raises(Github::Client::NotFound) { @client.repository(-42) }
    stub_request(:get, "#{API}/repositories/42").to_return(json_response(repo_json("acme/../secret", github_id: 42)))
    assert_raises(Github::Client::Error) { @client.repository(42) }
  end

  test "numeric repository IDs are used for both PR and file reads" do
    stub_request(:get, "#{API}/repositories/42/pulls/7")
      .to_return(json_response({ number: 7, title: "Current PR", head: { sha: "current-head" } }))
    stub_request(:get, "#{API}/repositories/42/pulls/7/files").with(query: hash_including({}))
      .to_return(json_response([ { filename: "current.rb", status: "added", patch: "+new" } ]))

    assert_equal "current-head", @client.pull_request(42, 7).head_sha
    file = @client.pull_request_files(42, 7).sole
    assert_equal [ "current.rb", "+new" ], [ file.filename, file.patch ]
  end

  test "pull_requests uses GraphQL and adds diff stats from a second query" do
    stub_request(:post, "#{API}/graphql")
      .with(body: hash_including(variables: hash_including(owner: "acme", name: "web")))
      .to_return do |request|
        if JSON.parse(request.body)["query"].include?("pullRequests(")
          json_response({ data: { repository: { databaseId: 42, pullRequests: { nodes: [
            { number: 7, title: "Fix login redirect", url: "https://github.com/acme/web/pull/7", isDraft: false,
              updatedAt: "2026-09-20T10:00:00Z", baseRefName: "main", headRefName: "fix-login", headRefOid: "f00d",
              author: { login: "ana", avatarUrl: "https://a/ana" } },
            { number: 9, title: "Bump rails", url: "https://github.com/acme/web/pull/9", isDraft: true,
              updatedAt: "2026-09-21T10:00:00Z", baseRefName: "main", headRefName: "bump", headRefOid: "beef", author: nil }
          ] } } } })
        else
          json_response({ data: { repository: { pr7: { number: 7, headRefOid: "f00d", additions: 12, deletions: 3 },
                                                pr9: { number: 9, headRefOid: "beef", additions: 1, deletions: 1 } } } })
        end
      end

    pulls = @client.pull_requests("acme/web")
    assert_equal [ 7, 9 ], pulls.map(&:number)
    assert_equal [ 12, 3 ], [ pulls.first.additions, pulls.first.deletions ]
    assert_equal "f00d", pulls.first.head_sha
    assert_nil pulls.last.author_login
    assert_requested(:post, "#{API}/graphql") { |request| !JSON.parse(request.body)["query"].include?("additions") }

    assert_equal [ 9 ], @client.pull_requests("acme/web", query: "#9").map(&:number)
    assert_equal [ 7 ], @client.pull_requests("acme/web", query: "ana").map(&:number)
  end

  test "the open PR list is cached briefly, and diff stats are fetched once per head commit" do
    head = "sha-1"
    stub_request(:post, "#{API}/graphql").to_return do |request|
      query = JSON.parse(request.body)["query"]
      if query.include?("pullRequests(")
        json_response({ data: { repository: { databaseId: 42, pullRequests: { nodes: [ pr_json(7, head: head), pr_json(8, head: "sha-8") ] } } } })
      else
        json_response({ data: { repository: query.scan(/pr(\d+):/).flatten.to_h do |number|
          [ "pr#{number}", { number: number.to_i, headRefOid: number == "7" ? head : "sha-8", additions: number.to_i * 10, deletions: 1 } ]
        end } })
      end
    end
    assert_stats_requested = ->(numbers) do
      assert_requested(:post, "#{API}/graphql") { |r| JSON.parse(r.body)["query"].scan(/pr(\d+):/).flatten == numbers }
    end

    with_memory_cache do
      2.times { assert_equal [ 70, 80 ], @client.pull_requests("acme/web").map(&:additions) }
      first_read = @client.fetched_at(:pull_requests)
      assert_requested :post, "#{API}/graphql", times: 2
      assert_stats_requested.([ "7", "8" ])

      head = "sha-2"
      travel 10.seconds do
        assert_equal [ 70, 80 ], @client.pull_requests("acme/web", fresh: true).map(&:additions)
        assert_operator @client.fetched_at(:pull_requests), :>, first_read
      end
      assert_stats_requested.([ "7" ])
      assert_requested :post, "#{API}/graphql", times: 4
    end
  end

  test "many missing diff stats come from one recent-list query instead of one lookup per PR" do
    count = Github::Client::DIFF_STATS_BY_NUMBER + 1
    stub_request(:post, "#{API}/graphql").to_return do |request|
      nodes = (1..count).map { |n| pr_json(n, head: "sha-#{n}") }
      if JSON.parse(request.body)["query"].include?("recent:")
        json_response({ data: { repository: { recent: { nodes: nodes.map { |pr| { number: pr[:number], headRefOid: pr[:headRefOid], additions: 5, deletions: 2 } } } } } })
      else
        json_response({ data: { repository: { databaseId: 42, pullRequests: { nodes: nodes } } } })
      end
    end

    assert_equal [ 5 ] * count, @client.pull_requests("acme/web").map(&:additions)
    assert_requested :post, "#{API}/graphql", times: 2
  end

  test "diff stats are left out when GitHub can't provide them" do
    stub_request(:post, "#{API}/graphql")
      .to_return(json_response({ data: { repository: { databaseId: 42, pullRequests: { nodes: [ pr_json(7) ] } } } }), json_response({}, status: 502))

    pr = @client.pull_requests("acme/web").sole
    assert_equal 7, pr.number
    assert_nil pr.additions
  end

  test "without a query, pull_requests asks for the recent list only" do
    stub_pulls_graphql({ repository: { pullRequests: { nodes: [ pr_json(7) ] } } })

    assert_equal [ 7 ], @client.pull_requests("acme/web").map(&:number)
    assert_requested(:post, "#{API}/graphql") do |request|
      JSON.parse(request.body)["variables"].values_at("byNumber", "byTitle", "byAuthor") == [ false, false, false ]
    end
  end

  test "a #number query finds an open PR outside the 100 most recently updated" do
    stub_pulls_graphql({ repository: { pullRequests: { nodes: [ pr_json(7) ] }, numbered: pr_json(3, updated_at: "2026-06-01T10:00:00Z") } })

    assert_equal [ 3 ], @client.pull_requests("acme/web", query: "#3").map(&:number)
    assert_requested(:post, "#{API}/graphql") do |request|
      JSON.parse(request.body)["variables"].values_at("byNumber", "number", "byTitle", "byAuthor") == [ true, 3, false, false ]
    end
  end

  test "a #number query ignores numbers that don't exist and PRs that are closed" do
    stub_pulls_graphql({ repository: { pullRequests: { nodes: [ pr_json(7) ] }, numbered: nil } },
                       errors: [ { type: "NOT_FOUND", path: %w[repository numbered], message: "Could not resolve to a PullRequest" } ])
    assert_empty @client.pull_requests("acme/web", query: "#404")

    stub_pulls_graphql({ repository: { pullRequests: { nodes: [] }, numbered: pr_json(3, state: "MERGED") } })
    assert_empty @client.pull_requests("acme/web", query: "3")
  end

  test "a text query searches titles of older PRs, quoting terms and staying in the repository" do
    stub_pulls_graphql({ repository: { pullRequests: { nodes: [ pr_json(7, title: "Fix login redirect") ] } },
                         byTitle: { nodes: [ pr_json(2, title: "Fix login on Safari", updated_at: "2026-07-01T10:00:00Z"),
                                             pr_json(5, title: "Fix login", repo: "other/repo"), {} ] } })

    assert_equal [ 7, 2 ], @client.pull_requests("acme/web", query: "fix login").map(&:number)
    assert_requested(:post, "#{API}/graphql") do |request|
      variables = JSON.parse(request.body)["variables"]
      variables["titleSearch"] == %(repo:acme/web is:pr is:open in:title "fix" "login") && !variables["byAuthor"]
    end

    @client.pull_requests("acme/web", query: %(repo:other/secret "x"))
    assert_requested(:post, "#{API}/graphql") do |request|
      JSON.parse(request.body).dig("variables", "titleSearch") == %(repo:acme/web is:pr is:open in:title "repo:other/secret" "x")
    end
  end

  test "a lone login-like term also searches authors" do
    stub_pulls_graphql({ repository: { pullRequests: { nodes: [] } }, byTitle: { nodes: [] },
                         byAuthor: { nodes: [ pr_json(4, author: "ana-b") ] } })

    assert_equal [ 4 ], @client.pull_requests("acme/web", query: "ana-b").map(&:number)
    assert_requested(:post, "#{API}/graphql") do |request|
      variables = JSON.parse(request.body)["variables"]
      variables["byAuthor"] && variables["authorSearch"] == "repo:acme/web is:pr is:open author:ana-b"
    end
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
    def stub_pulls_graphql(data, errors: nil)
      stub_request(:post, "#{API}/graphql").to_return(json_response({ data: data, errors: errors }.compact))
    end

    def pr_json(number, title: "PR #{number}", author: "ana", state: "OPEN", repo: "acme/web", updated_at: "2026-09-20T10:00:00Z", head: "sha")
      { number: number, title: title, url: "https://github.com/#{repo}/pull/#{number}", isDraft: false, state: state,
        updatedAt: updated_at, baseRefName: "main", headRefName: "topic", headRefOid: head, author: { login: author, avatarUrl: nil } }
    end

    def repo_json(full_name, github_id: Zlib.crc32(full_name))
      owner, name = full_name.split("/")
      { id: github_id, full_name: full_name, name: name, owner: { login: owner }, private: false,
        description: nil, pushed_at: "2026-09-20T10:00:00Z" }
    end
end
