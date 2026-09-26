# Sample GitHub and Jev data so the app can be tried in development with no OAuth app
# and no TypeSafe key. Off unless RAILS_ENV=development and JEV_PREVIEW=1.
#
# The data is local. Nothing is sent to GitHub or Jev, and the path does not exist
# in production.
module DevelopmentPreview
  UID = "preview"
  TOKEN = "preview"
  MODEL = "preview"

  def self.enabled?
    Rails.env.development? && ENV["JEV_PREVIEW"] == "1"
  end

  def self.user
    User.find_or_create_by!(github_uid: UID) do |user|
      user.login = "preview"
      user.name = "Preview"
      user.github_token = TOKEN
      user.github_created_at = 2.years.ago
    end
  end

  def self.repositories
    [
      repo("acme/web", "The storefront", private: false),
      repo("acme/billing", "Invoices and refunds", private: true),
      repo("acme/docs", "The public handbook", private: false)
    ]
  end

  def self.pull_requests(full_name)
    case full_name
    when "acme/web" then [ auth_pr, copy_pr ]
    when "acme/billing" then [ refund_pr ]
    else []
    end
  end

  def self.pull_request(full_name, number)
    pull_requests(full_name).find { |pr| pr.number == number.to_i } ||
      raise(Github::Client::NotFound, "That sample pull request isn't in the preview.")
  end

  def self.files_for(number)
    case number.to_i
    when 42
      [
        file("app/controllers/sessions_controller.rb", "modified", 18, 4),
        file("app/models/user.rb", "modified", 6, 1),
        file("config/initializers/omniauth.rb", "added", 9, 0)
      ]
    when 18
      [
        file("app/services/refunds.rb", "modified", 40, 12),
        file("db/migrate/20260901120000_add_refund_reason.rb", "added", 12, 0)
      ]
    else
      [ file("README.md", "modified", 2, 1) ]
    end
  end

  def self.diff_for(number)
    case number.to_i
    when 42
      <<~DIFF
        diff --git a/config/initializers/omniauth.rb b/config/initializers/omniauth.rb
        --- /dev/null
        +++ b/config/initializers/omniauth.rb
        @@
        +provider :github, id, secret, scope: "read:user,repo"
      DIFF
    when 18
      <<~DIFF
        diff --git a/app/services/refunds.rb b/app/services/refunds.rb
        @@
        -  refund.amount
        +  refund.amount_cents
      DIFF
    else
      <<~DIFF
        diff --git a/README.md b/README.md
        @@
        -teh
        +the
      DIFF
    end
  end

  # A stand-in for Jev. The choice is fixed per pull request so the three tags
  # are easy to see, and nothing is sent to TypeSafe.
  def self.jev_response(number)
    choice, probabilities, confidence = case number.to_i
    when 42 then [ "yes", { "yes" => 0.81, "llm_enough" => 0.14, "no" => 0.05 }, 0.72 ]
    when 18 then [ "llm_enough", { "yes" => 0.22, "llm_enough" => 0.68, "no" => 0.10 }, 0.61 ]
    else [ "no", { "yes" => 0.04, "llm_enough" => 0.11, "no" => 0.85 }, 0.8 ]
    end

    Jev::Client::Response.new(
      model: MODEL,
      answers: { PrReviewDecider::QUESTION_ID => { "choice" => choice, "probabilities" => probabilities, "confidence" => confidence } },
      usage: { "input_tokens" => 0, "output_tokens" => 0 }
    )
  end

  def self.repo(full_name, description, private:)
    owner, name = full_name.split("/", 2)
    Github::Client::Repository.new(full_name: full_name, name: name, owner: owner, private: private,
                                   description: description, pushed_at: Time.current)
  end

  def self.auth_pr
    pull(42, "Add GitHub sign-in", "Wires the OAuth callback and stores the token.", "acme/web",
         additions: 33, deletions: 5, changed_files: 3)
  end

  def self.copy_pr
    pull(7, "Fix a typo in the README", "teh → the.", "acme/web", additions: 2, deletions: 1, changed_files: 1)
  end

  def self.refund_pr
    pull(18, "Record why a refund was issued", "Adds a reason column and fills it from the form.", "acme/billing",
         additions: 52, deletions: 12, changed_files: 2)
  end

  def self.pull(number, title, body, repo, additions:, deletions:, changed_files:)
    Github::Client::PullRequest.new(
      number: number, title: title, body: body, html_url: "https://github.com/#{repo}/pull/#{number}",
      draft: false, author_login: "preview", author_avatar_url: nil, base_ref: "main", head_ref: "preview",
      head_sha: "preview-#{number}", additions: additions, deletions: deletions, changed_files: changed_files,
      updated_at: Time.current
    )
  end

  def self.file(filename, status, additions, deletions)
    Github::Client::FileChange.new(filename: filename, status: status, additions: additions, deletions: deletions)
  end
  private_class_method :repo, :auth_pr, :copy_pr, :refund_pr, :pull, :file
end
