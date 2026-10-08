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
    LIST_TTL = 5.minutes # The repository list, which is also proof of access for lists of saved verdicts
    PULL_REQUESTS_TTL = 1.minute
    DIFF_STATS_TTL = 30.days # Keyed by head commit, so they never go stale; this only bounds the cache
    DIFF_STATS_BY_NUMBER = 10
    PER_PAGE = 100
    FULL_NAME = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}

    # The 100 most recently updated open PRs, plus, when searching, the PR with that number and
    # GitHub search results by title and by author, so older PRs can be found too. All in one request.
    # Diff stats are left out: GitHub computes them per PR, which makes this query several times slower.
    OPEN_PULL_REQUESTS_QUERY = <<~GRAPHQL
      fragment PullRequestFields on PullRequest {
        number title url isDraft state updatedAt baseRefName headRefName headRefOid
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
      @fetched_at = {}
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

    # Most recently pushed first. Cached for a few minutes; lists of saved verdicts also treat it as
    # proof of access, so `fresh: true` (the Refresh button) re-reads it.
    def repositories(query: nil, fresh: false)
      repos = cached([ "github/repositories/v3", token_digest ], :repositories, expires_in: LIST_TTL, fresh: fresh) do
        paginate("/user/repos", { sort: "pushed", affiliation: "owner,collaborator,organization_member" }).map { |r| repository_from(r) }
      end

      filter(repos, query) { |repo| repo.full_name }
    end

    # Live with this viewer's token by default. Stable IDs keep renames and name reuse separate.
    # `cached: true` reuses a lookup, or a miss, for as long as the repository list is cached.
    def repository(identity, cached: false, fresh: false)
      return lookup_repository(identity) unless cached

      repo = Rails.cache.fetch([ "github/repository/v1", token_digest, identity.to_s.downcase ], expires_in: LIST_TTL, force: fresh) do
        lookup_repository(identity)
      rescue NotFound
        false
      end
      repo || raise(NotFound, "That repository isn't visible to you.")
    end

    # When a cached list (:repositories or :pull_requests) was last read from GitHub in this request.
    def fetched_at(list) = @fetched_at[list]

    # Open pull requests, most recently updated first, filtered by title, number or author.
    # Without a query it's the 100 most recently updated; a query also reaches older ones.
    # Cached briefly per viewer and search; `fresh: true` re-reads it.
    def pull_requests(full_name, query: nil, github_id: nil, fresh: false)
      owner, name = split_full_name(full_name)
      key = [ "github/pull_requests/v1", token_digest, full_name.downcase, query.to_s.split.join(" ") ]
      data = cached(key, :pull_requests, expires_in: PULL_REQUESTS_TTL, fresh: fresh) do
        graphql(OPEN_PULL_REQUESTS_QUERY, { owner: owner, name: name, **search_variables(full_name, query) },
                missing_ok: [ %w[repository numbered] ])
      end
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

      with_diff_stats(owner, name, data.dig("repository", "databaseId"), filter(pulls, query) { |pr| "##{pr.number} #{pr.title} #{pr.author_login}" })
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
      # The block's result, with when it was read, cached under key. Not for authorization on its own.
      def cached(key, list, expires_in:, fresh:)
        entry = Rails.cache.fetch(key, expires_in: expires_in, force: fresh) { { "at" => Time.current, "value" => yield } }
        @fetched_at[list] = entry["at"]
        entry["value"]
      end

      def lookup_repository(identity)
        repo = repository_from(get(repository_path(identity)).body)
        raise NotFound, "That repository isn't visible to you." if identity.is_a?(Integer) && repo.github_id != identity

        repo
      end

      # Additions and deletions, cached by repository, PR and head commit, so only new pushes are asked
      # for, in one request. Shared between viewers: the key needs a head commit from the viewer's own list.
      # Decorative, so a GitHub hiccup leaves them out rather than failing the list.
      def with_diff_stats(owner, name, repository_id, pulls)
        keys = pulls.select { |pr| pr.additions.nil? }.to_h { |pr| [ pr.number, [ "github/diff_stats/v1", repository_id, pr.number, pr.head_sha ] ] }
        return pulls if keys.empty?

        stats = Rails.cache.read_multi(*keys.values)
        missing = keys.keys.reject { |number| stats.key?(keys[number]) }
        stats.merge!(fetch_diff_stats(owner, name, repository_id, missing)) if missing.any?

        pulls.map do |pr|
          (diff = stats[keys[pr.number]]) ? pr.with(additions: diff["additions"], deletions: diff["deletions"]) : pr
        end
      end

      # A few PRs are asked for by number; for many (a first visit), GitHub answers the recent list faster.
      def fetch_diff_stats(owner, name, repository_id, numbers)
        selection = if numbers.size > DIFF_STATS_BY_NUMBER
          "recent: pullRequests(states: OPEN, first: 100, orderBy: { field: UPDATED_AT, direction: DESC }) { nodes { number headRefOid additions deletions } }"
        else
          numbers.map { |number| "pr#{Integer(number)}: pullRequest(number: #{Integer(number)}) { number headRefOid additions deletions }" }.join(" ")
        end
        data = graphql("query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { #{selection} } }",
                       { owner: owner, name: name }, missing_ok: numbers.map { |number| [ "repository", "pr#{number}" ] })
        repository = data["repository"].to_h
        nodes = repository.key?("recent") ? repository.dig("recent", "nodes") : repository.values.compact
        fetched = nodes.to_h do |pr|
          [ [ "github/diff_stats/v1", repository_id, pr["number"], pr["headRefOid"] ], pr.slice("additions", "deletions") ]
        end
        Rails.cache.write_multi(fetched, expires_in: DIFF_STATS_TTL)
        fetched
      rescue Unauthorized
        raise
      rescue Error
        {}
      end

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
