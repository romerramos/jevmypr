module Github
  # Same reads as Client, served from DevelopmentPreview. No token, no network.
  class PreviewClient
    def repositories(query: nil, fresh: false)
      filter(DevelopmentPreview.repositories, query) { |repo| repo.full_name }
    end

    def repository(identity)
      DevelopmentPreview.repositories.find { |repo| repo.github_id == identity || repo.full_name == identity } ||
        raise(Client::NotFound, "That repository isn't in the preview.")
    end

    def pull_requests(full_name, query: nil, github_id: nil)
      repo = repository(full_name)
      raise Client::NotFound, "That repository isn't in the preview." if github_id && github_id != repo.github_id

      filter(DevelopmentPreview.pull_requests(full_name), query) { |pr| "##{pr.number} #{pr.title} #{pr.author_login}" }
    end

    def pull_request(identity, number)
      DevelopmentPreview.pull_request(repository(identity).full_name, number)
    end

    def pull_request_files(identity, number)
      pull_request(identity, number)
      DevelopmentPreview.files_for(number)
    end

    private
      def filter(items, query)
        terms = query.to_s.downcase.split
        return items if terms.empty?

        items.select { |item| haystack = yield(item).downcase; terms.all? { |term| haystack.include?(term) } }
      end
  end
end
