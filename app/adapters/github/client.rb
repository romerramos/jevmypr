require "faraday"

module Github
  # Read-only GitHub API access on behalf of a signed-in user (their OAuth token).
  class Client
    class Error < StandardError; end
    class Unauthorized < Error; end
    class NotFound < Error; end

    Repository = Data.define(:github_id, :full_name, :name, :owner, :private, :description, :pushed_at)
    PullRequest = Data.define(:number, :title, :body, :html_url, :draft, :author_login, :author_avatar_url,
                              :base_ref, :head_ref, :head_sha, :additions, :deletions, :changed_files, :updated_at)
    FileChange = Data.define(:filename, :previous_filename, :status, :additions, :deletions, :patch)

    API_URL = "https://api.github.com"
    MAX_PAGES = 5
    PER_PAGE = 100
    FULL_NAME = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}

    # The 100 most recently updated open PRs, plus, when searching, the PR with that number and
    # GitHub search results by title and by author, so older PRs can be found too. All in one request.
    OPEN_PULL_REQUESTS_QUERY = <<~GRAPHQL
      fragment PullRequestFields on PullRequest {
        number title body url isDraft state updatedAt additions deletions changedFiles baseRefName headRefName headRefOid
        author { login avatarUrl }
      }

      query($owner: String!, $name: String!, $byNumber: Boolean!, $number: Int!,
            $byTitle: Boolean!, $titleSearch: String!, $byAuthor: Boolean!, $authorSearch: String!) {
        repository(owner: $owner, name: $name) {
          databaseId
          pullRequests(states: OPEN, first: 100, orderBy: { field: UPDATED_AT, direction: DESC }) {
            nodes { ...PullRequestFields }
          }
          numbered: pullRequest(number: $number) @include(if: $byNumber) { ...PullRequestFields }
        }
        byTitle: search(query: $titleSearch, type: ISSUE, first: 50) @include(if: $byTitle) { nodes { ...PullRequestFields } }
        byAuthor: search(query: $authorSearch, type: ISSUE, first: 50) @include(if: $byAuthor) { nodes { ...PullRequestFields } }
      }
    GRAPHQL
    MAX_PR_NUMBER = 2**31 - 1 # GraphQL Int
    GITHUB_LOGIN = /\A[a-z\d](?:[a-z\d-]{0,38})\z/i

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

    # The cached picker list is discovery, not authorization. History asks for a fresh list.
    def repositories(query: nil, fresh: false)
      repos = Rails.cache.fetch([ "github/repositories/v2", token_digest ], expires_in: 5.minutes, force: fresh) do
        paginate("/user/repos", { sort: "pushed", affiliation: "owner,collaborator,organization_member" }).map { |r| repository_from(r) }
      end

      filter(repos, query) { |repo| repo.full_name }
    end

    # Uncached, with this viewer's token. Stable IDs keep renames and name reuse separate.
    def repository(identity)
      repo = repository_from(get(repository_path(identity)).body)
      raise NotFound, "That repository isn't visible to you." if identity.is_a?(Integer) && repo.github_id != identity

      repo
    end

    # Open pull requests, most recently updated first, filtered by title, number or author.
    # Without a query it's the 100 most recently updated; a query also reaches older ones.
    def pull_requests(full_name, query: nil, github_id: nil)
      owner, name = split_full_name(full_name)
      data = graphql(OPEN_PULL_REQUESTS_QUERY, { owner: owner, name: name, **search_variables(full_name, query) },
                     missing_ok: [ %w[repository numbered] ])
      raise NotFound, "Repository #{full_name} wasn't found or isn't visible to you." if data["repository"].nil?
      if github_id && data.dig("repository", "databaseId") != github_id
        raise NotFound, "The repository identity changed. Choose it again from the repository list."
      end

      numbered = data.dig("repository", "numbered")
      # Search results are checked against the repository too, in case GitHub's search strays outside it.
      found = (Array(data.dig("byTitle", "nodes")) + Array(data.dig("byAuthor", "nodes")))
        .select { |pr| pr["url"].to_s.start_with?("https://github.com/#{full_name}/pull/") }
      # Anything not in the recent list is older than all of it, so it goes after, newest first.
      older = ([ numbered ].select { |pr| pr&.dig("state") == "OPEN" } + found).sort_by { |pr| pr["updatedAt"].to_s }.reverse
      nodes = data.dig("repository", "pullRequests", "nodes") + older
      pulls = nodes.uniq { |pr| pr["number"] }.map do |pr|
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

    # GitHub lists up to 3,000 files. Binary files and very large files come without a patch.
    def pull_request_files(full_name, number)
      paginate("#{pull_path(full_name, number)}/files", {}, max_pages: 30).map do |f|
        FileChange.new(filename: f["filename"], previous_filename: f["previous_filename"], status: f["status"],
                       additions: f["additions"], deletions: f["deletions"], patch: f["patch"])
      end
    end

    private
      def get(path, params = {}, headers: {})
        response = @connection.get(path, params, headers)
        handle_errors!(response)
        response
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
        raise Error, "Couldn't reach GitHub (#{e.class.name.demodulize})."
      end

      def paginate(path, params = {}, max_pages: MAX_PAGES)
        results = []
        response = get(path, params.merge(per_page: PER_PAGE))

        max_pages.times do
          results.concat(response.body)
          next_url = next_page_url(response)
          break unless next_url

          response = get(next_url)
        end

        results
      end

      # missing_ok: paths of optional lookups that may not resolve, like a PR number that doesn't exist.
      def graphql(query, variables, missing_ok: [])
        response = @connection.post("/graphql", { query: query, variables: variables })
        handle_errors!(response)

        errors = Array(response.body["errors"]).reject { |e| e["type"] == "NOT_FOUND" && missing_ok.include?(e["path"]) }
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

      # A "#123" or "123" term looks that PR up directly; GitHub search treats numbers as text. Other terms
      # search titles, quoted so they can't act as search qualifiers. A lone login-like term also searches authors.
      def search_variables(full_name, query)
        terms = query.to_s.split
        number = terms.filter_map { |t| t.delete_prefix("#").to_i if t.match?(/\A#?\d+\z/) }.find { |n| n.between?(1, MAX_PR_NUMBER) }
        words = terms.reject { |t| t.match?(/\A#?\d+\z/) }.map { |t| t.delete('"') }.reject(&:empty?)
        scope = "repo:#{full_name} is:pr is:open"

        { byNumber: !number.nil?, number: number || 0,
          byTitle: words.any?, titleSearch: "#{scope} in:title #{words.map { |w| %("#{w}") }.join(" ")}",
          byAuthor: terms.one? && words.one? && words.first.match?(GITHUB_LOGIN), authorSearch: "#{scope} author:#{words.first}" }
      end

      def split_full_name(full_name)
        raise NotFound, "Repository names look like owner/name." unless full_name.to_s.match?(FULL_NAME) && !full_name.include?("..")

        full_name.split("/", 2)
      end

      def repository_from(data)
        unless data["id"].is_a?(Integer) && data["id"].positive? && data["full_name"].to_s.match?(FULL_NAME) && !data["full_name"].include?("..")
          raise Error, "GitHub didn't return a valid repository identity."
        end

        Repository.new(github_id: data["id"], full_name: data["full_name"], name: data["name"], owner: data.dig("owner", "login"),
                       private: data["private"], description: data["description"], pushed_at: time(data["pushed_at"]))
      end

      def repository_path(identity)
        if identity.is_a?(Integer)
          raise NotFound, "Repository IDs are positive integers." unless identity.positive?

          "/repositories/#{identity}"
        else
          owner, name = split_full_name(identity)
          "/repos/#{owner}/#{name}"
        end
      end

      def pull_path(full_name, number)
        "#{repository_path(full_name)}/pulls/#{Integer(number, exception: false) || raise(NotFound, "Pull request numbers are whole numbers.")}"
      end

      def time(value)
        Time.zone.parse(value) if value
      end

      def token_digest
        Digest::SHA256.hexdigest(@token)
      end
  end
end
