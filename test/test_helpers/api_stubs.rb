# WebMock stubs for the GitHub and Jev APIs, shared by controller tests.
module ApiStubs
  GITHUB = Github::Client::API_URL

  def github_repository_id(full_name)
    { "acme/web" => 101, "acme/billing" => 102, "acme/docs" => 103, "acme/vault" => 104 }.fetch(full_name) { Zlib.crc32(full_name) + 1_000 }
  end

  def repository_json(full_name, github_id: github_repository_id(full_name))
    owner, name = full_name.split("/")
    { id: github_id, full_name: full_name, name: name, owner: { login: owner }, private: name.include?("secret"), description: nil, pushed_at: 2.hours.ago.iso8601 }
  end

  def stub_github_repository(full_name = "acme/web", github_id: github_repository_id(full_name), token: nil, status: 200)
    [ "repos/#{full_name}", "repositories/#{github_id}" ].each do |path|
      stub = stub_request(:get, "#{GITHUB}/#{path}")
      stub.with(headers: { "Authorization" => "Bearer #{token}" }) if token
      stub.to_return(json_response(status == 200 ? repository_json(full_name, github_id: github_id) : {}, status: status))
    end
  end

  def stub_github_repositories(*full_names, token: nil)
    repos = full_names.map do |full_name|
      stub_github_repository(full_name, token: token)
      repository_json(full_name)
    end
    stub = stub_request(:get, "#{GITHUB}/user/repos").with(query: hash_including({}))
    stub.with(headers: { "Authorization" => "Bearer #{token}" }) if token
    stub.to_return(json_response(repos))
  end

  def stub_github_pull_requests(nodes, repo: "acme/web", github_id: nil)
    stub_github_repository(repo, github_id: github_id || github_repository_id(repo))
    stub_request(:post, "#{GITHUB}/graphql").to_return do |request|
      variables = JSON.parse(request.body)["variables"]
      id = github_id || github_repository_id("#{variables['owner']}/#{variables['name']}")
      json_response({ data: { repository: { databaseId: id, pullRequests: { nodes: nodes } } } })
    end
  end

  def pull_request_node(number:, title:, author: "ana", draft: false, head_sha: "sha-#{number}")
    { number: number, title: title, body: "", url: "https://github.com/acme/web/pull/#{number}", isDraft: draft,
      updatedAt: 1.hour.ago.iso8601, additions: 12, deletions: 3, changedFiles: 1, baseRefName: "main", headRefName: "topic", headRefOid: head_sha,
      author: { login: author, avatarUrl: "https://avatars.example/#{author}" } }
  end

  def stub_github_pull_request(repo: "acme/web", number: 7, title: "Fix login redirect", head_sha: "sha-#{number}", github_id: github_repository_id(repo))
    stub_github_repository(repo, github_id: github_id)
    [ "repos/#{repo}", "repositories/#{github_id}" ].each do |path|
      stub_request(:get, "#{GITHUB}/#{path}/pulls/#{number}")
        .with(headers: { "Accept" => "application/vnd.github+json" })
        .to_return(json_response(pull_request_json(repo: repo, number: number, title: title, head_sha: head_sha)))
      stub_request(:get, "#{GITHUB}/#{path}/pulls/#{number}/files").with(query: hash_including({}))
        .to_return(json_response([ { filename: "app/controllers/sessions_controller.rb", status: "modified", additions: 12, deletions: 3,
                                     patch: "@@ -1 +1 @@\n-old\n+new" } ]))
    end
  end

  def pull_request_json(repo: "acme/web", number: 7, title: "Fix login redirect", head_sha: "sha-#{number}")
    { number: number, title: title, body: "", html_url: "https://github.com/#{repo}/pull/#{number}", draft: false,
      user: { login: "ana", avatar_url: nil }, base: { ref: "main" }, head: { ref: "topic", sha: head_sha },
      additions: 12, deletions: 3, changed_files: 1, updated_at: 1.hour.ago.iso8601 }
  end

  # Answers the PR question and the question for the PR's one file (file_0) the same way.
  def stub_jev(choice:, probabilities: { "yes" => 0.7, "llm_enough" => 0.2, "no" => 0.1 }, confidence: 0.6)
    answer = { type: "choice", choice: choice, probabilities: probabilities, confidence: confidence }
    stub_request(:post, Jev::Client::URL).to_return(json_response({
      model: "jev-1.13.0",
      answers: { PrReviewDecider::QUESTION_ID => answer, "#{PrReviewDecider::FILE_QUESTION_PREFIX}0" => answer },
      usage: { input_tokens: 10, output_tokens: 2 }
    }))
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) do
  include ApiStubs
end
