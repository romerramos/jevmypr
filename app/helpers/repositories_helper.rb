module RepositoriesHelper
  # "owner/name" → /repositories/owner/name/pull_requests
  def pull_requests_path_for(full_name, **params)
    owner, repo = full_name.split("/", 2)
    repository_pull_requests_path(owner: owner, repo: repo, **params)
  end

  def assessments_path_for(full_name, number)
    owner, repo = full_name.split("/", 2)
    repository_pull_request_assessments_path(owner: owner, repo: repo, pull_request_number: number)
  end

  def pin_path_for(full_name, **params)
    owner, repo = full_name.split("/", 2)
    repository_pin_path(owner: owner, repo: repo, **params)
  end
end
