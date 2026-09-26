# WebMock stubs for the GitHub and Jev APIs, shared by controller tests.
module ApiStubs
  GITHUB = Github::Client::API_URL

  def stub_github_repositories(*full_names)
    repos = full_names.map do |full_name|
      owner, name = full_name.split("/")
      { full_name: full_name, name: name, owner: { login: owner }, private: name.include?("secret"), description: nil, pushed_at: 2.hours.ago.iso8601 }
    end
    stub_request(:get, "#{GITHUB}/user/repos").with(query: hash_including({})).to_return(json_response(repos))
  end

  def stub_github_pull_requests(nodes)
    stub_request(:post, "#{GITHUB}/graphql").to_return(json_response({ data: { repository: { pullRequests: { nodes: nodes } } } }))
  end

  def pull_request_node(number:, title:, author: "ana", draft: false, head_sha: "sha-#{number}")
    { number: number, title: title, body: "", url: "https://github.com/acme/web/pull/#{number}", isDraft: draft,
      updatedAt: 1.hour.ago.iso8601, additions: 12, deletions: 3, changedFiles: 1, baseRefName: "main", headRefName: "topic", headRefOid: head_sha,
      author: { login: author, avatarUrl: "https://avatars.example/#{author}" } }
  end

  def stub_github_pull_request(repo: "acme/web", number: 7, title: "Fix login redirect", head_sha: "sha-#{number}")
    stub_request(:get, "#{GITHUB}/repos/#{repo}/pulls/#{number}")
      .with(headers: { "Accept" => "application/vnd.github+json" })
      .to_return(json_response({ number: number, title: title, body: "", html_url: "https://github.com/#{repo}/pull/#{number}", draft: false,
                                 user: { login: "ana", avatar_url: nil }, base: { ref: "main" }, head: { ref: "topic", sha: head_sha },
                                 additions: 12, deletions: 3, changed_files: 1, updated_at: 1.hour.ago.iso8601 }))
    stub_request(:get, "#{GITHUB}/repos/#{repo}/pulls/#{number}/files").with(query: hash_including({}))
      .to_return(json_response([ { filename: "app/controllers/sessions_controller.rb", status: "modified", additions: 12, deletions: 3 } ]))
    stub_request(:get, "#{GITHUB}/repos/#{repo}/pulls/#{number}")
      .with(headers: { "Accept" => "application/vnd.github.diff" })
      .to_return(status: 200, body: "diff --git a/x b/x\n", headers: { "Content-Type" => "application/vnd.github.diff" })
  end

  def stub_jev(choice:, probabilities: { "yes" => 0.7, "llm_enough" => 0.2, "no" => 0.1 }, confidence: 0.6)
    stub_request(:post, Jev::Client::URL).to_return(json_response({
      model: "jev-1.13.0",
      answers: { PrReviewDecider::QUESTION_ID => { type: "choice", choice: choice, probabilities: probabilities, confidence: confidence } },
      usage: { input_tokens: 10, output_tokens: 2 }
    }))
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) do
  include ApiStubs
end
