# Sample GitHub and Jev data so the app can be tried with no OAuth app and no TypeSafe key.
# On in development when any of those is missing, so the app is never half-configured,
# or when PREVIEW_MODE=1 is set. Never on in production. The data is local: nothing
# is sent to GitHub or Jev.
module DevelopmentPreview
  UID = "preview"
  TOKEN = "preview"
  MODEL = "preview"
  REQUIRED_SECRETS = %i[github_client_id github_client_secret typesafe_api_key].freeze
  ANSWERS = {
    "yes" => { "choice" => "yes", "probabilities" => { "yes" => 0.81, "llm_enough" => 0.14, "no" => 0.05 }, "confidence" => 0.72 },
    "llm_enough" => { "choice" => "llm_enough", "probabilities" => { "yes" => 0.22, "llm_enough" => 0.68, "no" => 0.10 }, "confidence" => 0.61 },
    "no" => { "choice" => "no", "probabilities" => { "yes" => 0.04, "llm_enough" => 0.11, "no" => 0.85 }, "confidence" => 0.8 }
  }.freeze
  PULL_REQUEST_CHOICES = { 42 => "yes", 18 => "llm_enough", 7 => "no" }.freeze
  FILE_CHOICES = {
    "app/controllers/sessions_controller.rb" => "yes",
    "config/initializers/omniauth.rb" => "yes",
    "db/migrate/20260901120000_add_refund_reason.rb" => "yes",
    "README.md" => "no"
  }.freeze

  def self.enabled?
    return false unless Rails.env.development?
    return true if ENV["PREVIEW_MODE"] == "1"

    REQUIRED_SECRETS.any? { |name| AppSecrets[name].blank? }
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
      repo(-101, "acme/web", "The storefront", private: false),
      repo(-102, "acme/billing", "Invoices and refunds", private: true),
      repo(-103, "acme/docs", "The public handbook", private: false)
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
        file("app/controllers/sessions_controller.rb", "modified", "@@ -8,3 +8,6 @@\n   def create\n-    head :ok\n+    user = User.from_omniauth(request.env[\"omniauth.auth\"])\n+    start_new_session_for user\n+    redirect_to root_path\n   end"),
        file("app/models/user.rb", "modified", "@@ -1,2 +1,3 @@\n class User < ApplicationRecord\n+  encrypts :github_token\n end"),
        file("config/initializers/omniauth.rb", "added", "@@ -0,0 +1 @@\n+provider :github, id, secret, scope: \"read:user,repo\"")
      ]
    when 18
      [
        file("app/services/refunds.rb", "modified", "@@ -12 +12,2 @@\n-    refund.update!(amount: amount)\n+    refund.update!(amount: amount, reason: reason)"),
        file("db/migrate/20260901120000_add_refund_reason.rb", "added", "@@ -0,0 +1 @@\n+add_column :refunds, :reason, :string")
      ]
    else
      [
        file("README.md", "modified", "@@ -3 +3 @@\n-Read teh guide.\n+Read the guide."),
        file("public/logo.png", "modified", nil)
      ]
    end
  end

  # A stand-in for Jev. Each sample pull request and file has a fixed verdict so the
  # three tags are easy to see, and nothing is sent to TypeSafe.
  def self.jev_response(state:, questions:)
    pull_request = pull_requests(state[:repository]).find { |pr| pr.title == state[:title] }
    answers = questions.keys.to_h do |id|
      choice = if id == PrReviewDecider::QUESTION_ID
        PULL_REQUEST_CHOICES.fetch(pull_request&.number, "no")
      else
        filename = state[:files][id.delete_prefix(PrReviewDecider::FILE_QUESTION_PREFIX).to_i][:filename]
        FILE_CHOICES.fetch(filename, "llm_enough")
      end
      [ id, ANSWERS.fetch(choice) ]
    end

    Jev::Client::Response.new(model: MODEL, answers: answers, usage: { "input_tokens" => 0, "output_tokens" => 0 })
  end

  def self.repo(github_id, full_name, description, private:)
    owner, name = full_name.split("/", 2)
    Github::Client::Repository.new(github_id: github_id, full_name: full_name, name: name, owner: owner, private: private,
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

  def self.file(filename, status, patch)
    lines = patch.to_s.lines
    Github::Client::FileChange.new(filename: filename, previous_filename: nil, status: status, patch: patch,
                                   additions: lines.count { |line| line.start_with?("+") },
                                   deletions: lines.count { |line| line.start_with?("-") })
  end
  private_class_method :repo, :auth_pr, :copy_pr, :refund_pr, :pull, :file
end
