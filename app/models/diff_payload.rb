# A diff sent without a GitHub pull request behind it, turned into the pull request and file objects
# Github::Client returns, so PrReviewDecider can read it with no GitHub call:
#
#   payload = DiffPayload.new(title: "Add refunds", files: [ { filename: "app/refund.rb", status: "added", patch: "@@ ..." } ])
#   PrReviewDecider.new(github: nil).decide(payload.repository, nil, pull_request: payload.pull_request, files: payload.files) if payload.valid?
#
# Patches are GitHub-style: the hunks of one file, without the `diff --git`, `---` and `+++` headers.
class DiffPayload
  include ActiveModel::Validations

  STATUSES = %w[added removed modified renamed copied changed unchanged].freeze
  # The decider reads at most PrReviewDecider::MAX_DIFF_BYTES and leaves out the rest, so anything far beyond it is refused.
  MAX_PATCH_BYTES = 1_000_000
  MAX_FILES = 3_000 # As many as GitHub lists for a pull request
  MAX_FILENAME_LENGTH = 1_024
  MAX_TITLE_LENGTH = 300
  MAX_DESCRIPTION_LENGTH = 20_000 # The decider sends Jev the first 5,000 characters
  MAX_NAME_LENGTH = 255 # Repository and branch names
  DEFAULT_TITLE = "Untitled change"
  # For `params.expect(diff: DiffPayload::PERMITTED)` in a controller.
  PERMITTED = [ :repository, :title, :description, :base_branch, :head_branch,
                files: [ [ :filename, :previous_filename, :status, :additions, :deletions, :patch ] ] ].freeze

  attr_reader :repository, :title, :description, :base_branch, :head_branch

  validate :check_names, :check_files

  def initialize(attributes = {})
    attributes = attributes.to_h.with_indifferent_access
    @repository, @title, @description, @base_branch, @head_branch =
      attributes.values_at(:repository, :title, :description, :base_branch, :head_branch).map { |value| blank_to_nil(value) }
    @raw_files = attributes[:files]
  end

  def files
    @files ||= Array(@raw_files).map do |file|
      file = file.to_h.with_indifferent_access
      patch = blank_to_nil(file[:patch])
      Github::Client::FileChange.new(filename: file[:filename], previous_filename: blank_to_nil(file[:previous_filename]),
                                     status: blank_to_nil(file[:status]) || "modified",
                                     additions: file[:additions] || count_lines(patch, "+"),
                                     deletions: file[:deletions] || count_lines(patch, "-"), patch: patch)
    end
  end

  def pull_request
    @pull_request ||= Github::Client::PullRequest.new(
      number: nil, title: title || DEFAULT_TITLE, body: description, html_url: nil, draft: false,
      author_login: nil, author_avatar_url: nil, base_ref: base_branch, head_ref: head_branch, head_sha: sha256,
      additions: files.sum(&:additions), deletions: files.sum(&:deletions), changed_files: files.size, updated_at: nil
    )
  end

  # Identifies the change itself (files and patches), so the same diff sent twice can reuse its verdict.
  # Stands in for the head commit, which a sent diff doesn't have.
  def sha256
    @sha256 ||= Digest::SHA256.hexdigest(files.map { |f| [ f.filename, f.previous_filename, f.status, f.patch ] }.to_json)
  end

  # Full messages, without repeating "Files" before a message about one file ("files[2].status must be ...").
  def error_messages
    errors.map { |error| error.message.start_with?("files[") ? error.message : error.full_message }
  end

  private
    # Like `presence`, but leaves badly encoded text in place for the validations to report.
    def blank_to_nil(value)
      value.is_a?(String) && value.valid_encoding? && value.blank? ? nil : value
    end

    def count_lines(patch, sign)
      patch.to_s.each_line.count { |line| line.start_with?(sign) }
    end

    def check_names
      { repository: MAX_NAME_LENGTH, base_branch: MAX_NAME_LENGTH, head_branch: MAX_NAME_LENGTH,
        title: MAX_TITLE_LENGTH, description: MAX_DESCRIPTION_LENGTH }.each do |name, limit|
        value = public_send(name)
        next if value.nil?

        if !value.is_a?(String) || !value.valid_encoding?
          errors.add(name, "must be text")
        elsif value.length > limit
          errors.add(name, "is too long (at most #{limit} characters)")
        end
      end
    end

    def check_files
      unless @raw_files.is_a?(Array) && @raw_files.all? { |file| file.respond_to?(:to_h) && !file.is_a?(Array) }
        return errors.add(:files, "must be a list of files")
      end
      return errors.add(:files, "can't be empty") if @raw_files.empty?
      return errors.add(:files, "has too many entries (at most #{MAX_FILES})") if @raw_files.size > MAX_FILES

      files.each_with_index { |file, i| check_file(file, "files[#{i}]") }
      return if errors.any?

      bytes = files.sum { |file| file.patch.to_s.bytesize }
      errors.add(:files, "have patches that are too big (#{bytes} bytes, at most #{MAX_PATCH_BYTES})") if bytes > MAX_PATCH_BYTES
    end

    def check_file(file, name)
      unless file.filename.is_a?(String) && file.filename.present? && file.filename.valid_encoding? && file.filename.length <= MAX_FILENAME_LENGTH
        errors.add(:files, "#{name}.filename must be a path of at most #{MAX_FILENAME_LENGTH} characters")
      end
      unless file.previous_filename.nil? || (file.previous_filename.is_a?(String) && file.previous_filename.valid_encoding? &&
                                             file.previous_filename.length <= MAX_FILENAME_LENGTH)
        errors.add(:files, "#{name}.previous_filename must be a path of at most #{MAX_FILENAME_LENGTH} characters")
      end
      errors.add(:files, "#{name}.status must be one of #{STATUSES.to_sentence(last_word_connector: ' or ')}") unless STATUSES.include?(file.status)
      %i[additions deletions].each do |count|
        errors.add(:files, "#{name}.#{count} must be a whole number of at least 0") unless file.public_send(count).is_a?(Integer) && file.public_send(count) >= 0
      end
      errors.add(:files, "#{name}.patch must be text") unless file.patch.nil? || (file.patch.is_a?(String) && file.patch.valid_encoding?)
    end
end
