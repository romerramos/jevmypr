require "faraday"

module Github
  # Read-only GitHub API access on behalf of a signed-in user (their OAuth token).
  class Client
    class Error < StandardError; end
    class Unauthorized < Error; end
    class NotFound < Error; end

    Repository = Data.define(:full_name, :name, :owner, :private, :description, :pushed_at)
    PullRequest = Data.define(:number, :title, :body, :html_url, :draft, :author_login, :author_avatar_url,
                              :base_ref, :head_ref, :head_sha, :additions, :deletions, :changed_files, :updated_at)
    FileChange = Data.define(:filename, :status, :additions, :deletions)

    API_URL = "https://api.github.com"
    MAX_PAGES = 5
    PER_PAGE = 100
    FULL_NAME = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}

    OPEN_PULL_REQUESTS_QUERY = <<~GRAPHQL
      query($owner: String!, $name: String!) {
        repository(owner: $owner, name: $name) {
          pullRequests(states: OPEN, first: 100, orderBy: { field: UPDATED_AT, direction: DESC }) {
            nodes {
              number title body url isDraft updatedAt additions deletions changedFiles baseRefName headRefName headRefOid
              author { login avatarUrl }
            }
          }
        }
      }
    GRAPHQL

    def initialize(token)
      raise Unauthorized, "Missing GitHub token. Sign in again." if token.blank?

      @token = token
      @connection = Faraday.new(url: API_URL) do |f|
        f.request :authorization, "Bearer", token
        f.request :json
        f.response :json, content_type: /\bjson$/
        f.headers["Accept"] = "application/vnd.github+json"
        f.headers["X-GitHub-Api-Version"] = "2022-11-28"
        f.headers["User-Agent"] = "jev-my-pr"
        f.options.timeout = 20
        f.options.open_timeout = 5
      end
    end

    # Repositories the user can access, most recently pushed first, filtered by name.
    def repositories(query: nil)
      repos = Rails.cache.fetch([ "github/repositories", token_digest ], expires_in: 5.minutes) do
        paginate("/user/repos", sort: "pushed", affiliation: "owner,collaborator,organization_member").map do |r|
          Repository.new(full_name: r["full_name"], name: r["name"], owner: r.dig("owner", "login"),
                         private: r["private"], description: r["description"], pushed_at: time(r["pushed_at"]))
        end
      end

      filter(repos, query) { |repo| repo.full_name }
    end

    # Open pull requests, most recently updated first, filtered by title, number or author.
    def pull_requests(full_name, query: nil)
      owner, name = split_full_name(full_name)
      data = graphql(OPEN_PULL_REQUESTS_QUERY, owner: owner, name: name)
      raise NotFound, "Repository #{full_name} wasn't found or isn't visible to you." if data["repository"].nil?

      pulls = data.dig("repository", "pullRequests", "nodes").map do |pr|
        PullRequest.new(number: pr["number"], title: pr["title"], body: pr["body"], html_url: pr["url"], draft: pr["isDraft"],
                        author_login: pr.dig("author", "login"), author_avatar_url: pr.dig("author", "avatarUrl"),
                        base_ref: pr["baseRefName"], head_ref: pr["headRefName"], head_sha: pr["headRefOid"], additions: pr["additions"],
                        deletions: pr["deletions"], changed_files: pr["changedFiles"], updated_at: time(pr["updatedAt"]))
      end

      filter(pulls, query) { |pr| "##{pr.number} #{pr.title} #{pr.author_login}" }
    end

    def pull_request(full_name, number)
      pr = get(pull_path(full_name, number)).body

      PullRequest.new(number: pr["number"], title: pr["title"], body: pr["body"], html_url: pr["html_url"], draft: pr["draft"],
                      author_login: pr.dig("user", "login"), author_avatar_url: pr.dig("user", "avatar_url"),
                      base_ref: pr.dig("base", "ref"), head_ref: pr.dig("head", "ref"), head_sha: pr.dig("head", "sha"), additions: pr["additions"],
                      deletions: pr["deletions"], changed_files: pr["changed_files"], updated_at: time(pr["updated_at"]))
    end

    def pull_request_files(full_name, number)
      paginate("#{pull_path(full_name, number)}/files").map do |f|
        FileChange.new(filename: f["filename"], status: f["status"], additions: f["additions"], deletions: f["deletions"])
      end
    end

    # Unified diff as text.
    def pull_request_diff(full_name, number)
      get(pull_path(full_name, number), headers: { "Accept" => "application/vnd.github.diff" }).body
    end

    private
      def get(path, params = {}, headers: {})
        response = @connection.get(path, params, headers)
        handle_errors!(response)
        response
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
        raise Error, "Couldn't reach GitHub (#{e.class.name.demodulize})."
      end

      def paginate(path, params = {})
        results = []
        response = get(path, params.merge(per_page: PER_PAGE))

        MAX_PAGES.times do
          results.concat(response.body)
          next_url = next_page_url(response)
          break unless next_url

          response = get(next_url)
        end

        results
      end

      def graphql(query, variables)
        response = @connection.post("/graphql", { query: query, variables: variables })
        handle_errors!(response)

        errors = response.body["errors"]
        if errors.present?
          raise NotFound, errors.first["message"] if errors.any? { |e| e["type"] == "NOT_FOUND" }
          raise Error, "GitHub GraphQL error: #{errors.map { |e| e["message"] }.to_sentence}"
        end

        response.body["data"]
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
        raise Error, "Couldn't reach GitHub (#{e.class.name.demodulize})."
      end

      def handle_errors!(response)
        case response.status
        when 200..299 then nil
        when 401 then raise Unauthorized, "GitHub rejected your session. Sign in again."
        when 404 then raise NotFound, "GitHub couldn't find that repository or pull request."
        when 403, 429
          raise Error, "GitHub rate limit reached. Try again in a few minutes." if response.headers["x-ratelimit-remaining"] == "0" || response.status == 429
          raise Error, "GitHub denied access (HTTP 403). The repository may need extra permissions."
        else raise Error, "GitHub returned HTTP #{response.status}."
        end
      end

      def next_page_url(response)
        response.headers["link"].to_s.split(",").find { |link| link.include?('rel="next"') }&.then { |link| link[/<([^>]+)>/, 1] }
      end

      def filter(items, query)
        terms = query.to_s.downcase.split
        return items if terms.empty?

        items.select { |item| haystack = yield(item).downcase; terms.all? { |term| haystack.include?(term) } }
      end

      def split_full_name(full_name)
        raise NotFound, "Repository names look like owner/name." unless full_name.to_s.match?(FULL_NAME) && !full_name.include?("..")

        full_name.split("/", 2)
      end

      def pull_path(full_name, number)
        owner, name = split_full_name(full_name)
        "/repos/#{owner}/#{name}/pulls/#{Integer(number, exception: false) || raise(NotFound, "Pull request numbers are whole numbers.")}"
      end

      def time(value)
        Time.zone.parse(value) if value
      end

      def token_digest
        Digest::SHA256.hexdigest(@token)
      end
  end
end
