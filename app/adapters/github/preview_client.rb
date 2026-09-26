module Github
  # Same reads as Client, served from DevelopmentPreview. No token, no network.
  class PreviewClient
    def repositories(query: nil)
      filter(DevelopmentPreview.repositories, query) { |repo| repo.full_name }
    end

    def pull_requests(full_name, query: nil)
      known!(full_name)
      filter(DevelopmentPreview.pull_requests(full_name), query) { |pr| "##{pr.number} #{pr.title} #{pr.author_login}" }
    end

    def pull_request(full_name, number)
      known!(full_name)
      DevelopmentPreview.pull_request(full_name, number)
    end

    def pull_request_files(_full_name, number)
      DevelopmentPreview.files_for(number)
    end

    def pull_request_diff(_full_name, number)
      DevelopmentPreview.diff_for(number)
    end

    private
      def known!(full_name)
        return if DevelopmentPreview.repositories.any? { |repo| repo.full_name == full_name }

        raise Client::NotFound, "Repository #{full_name} isn't in the preview."
      end

      def filter(items, query)
        terms = query.to_s.downcase.split
        return items if terms.empty?

        items.select { |item| haystack = yield(item).downcase; terms.all? { |term| haystack.include?(term) } }
      end
  end
end
