# Asks Jev whether a pull request needs a human review, based on its description and changed files.
# The same request asks the question for each changed file too: Jev reads the PR once and answers
# every question in parallel, so the file verdicts cost a few tokens and no extra request.
#
#   PrReviewDecider.new(github: Github::Client.new(token)).decide("owner/repo", 42)
class PrReviewDecider
  QUESTION_ID = "needs_human_review"
  FILE_QUESTION_PREFIX = "file_"
  CHOICES = {
    "yes" => "Risky or complex changes (security, auth, payments, data migrations, architecture, core business logic, " \
             "concurrency) where mistakes are costly. A human must review.",
    "llm_enough" => "Non-trivial but low-risk changes (small features, refactors, tests, contained bug fixes) where an " \
                    "automated LLM review is sufficient.",
    "no" => "Trivial and safe changes (typos, docs, formatting, comments, version bumps, generated files) that need no review."
  }.freeze
  MAX_DIFF_BYTES = 100_000
  # Each file question repeats the criteria (about 100 tokens), so this keeps them well inside Jev's 64k context.
  MAX_FILE_QUESTIONS = 100

  # The pull request is too big for Jev to read, even with the diff cut to MAX_DIFF_BYTES.
  class TooLarge < Jev::Client::Error
    attr_reader :pull_request

    def initialize(pull_request)
      @pull_request = pull_request
      super("##{pull_request.number} is too big for Jev to read in one go.")
    end
  end

  Decision = Data.define(:choice, :probabilities, :confidence, :model)
  # A file's verdict, or why there is none (skipped: :no_patch, :too_large, :too_many or :no_answer).
  FileVerdict = Data.define(:file, :decision, :skipped)
  Result = Data.define(:pull_request, :files, :decision, :diff_truncated, :usage)

  def initialize(github:, jev: Jev::Client.new)
    @github = github
    @jev = jev
  end

  def decide(full_name, number, pull_request: nil, files: nil)
    pull_request ||= @github.pull_request(full_name, number)
    files ||= @github.pull_request_files(full_name, number)
    patches = patches_within_budget(files)
    asked = files.each_index.select { |i| patches[i] }.first(MAX_FILE_QUESTIONS)

    response = begin
      @jev.ask(state: state_for(full_name, pull_request, files, patches), questions: questions_for(asked))
    rescue Jev::Client::TooLarge
      raise TooLarge, pull_request
    end
    yield response.usage.to_h if block_given?

    verdicts = files.each_with_index.map do |file, i|
      decision = file_decision(response, i) if asked.include?(i)
      skipped = if decision then nil
      elsif file.patch.blank? then :no_patch
      elsif patches[i].nil? then :too_large
      elsif asked.include?(i) then :no_answer
      else :too_many
      end
      FileVerdict.new(file: file, decision: decision, skipped: skipped)
    end

    Result.new(pull_request: pull_request, files: verdicts, decision: decision_from(response, QUESTION_ID),
               diff_truncated: patches.compact.size < files.count { |f| f.patch.present? }, usage: response.usage.to_h)
  end

  private
    def questions_for(file_indexes)
      file_questions = file_indexes.to_h do |i|
        [ "#{FILE_QUESTION_PREFIX}#{i}", question("Does the change to `files[#{i}]` need a review from a human?") ]
      end
      { QUESTION_ID => question("Does this PR need a review from a human?") }.merge(file_questions)
    end

    def question(instructions)
      { type: "choice", instructions: instructions, criteria: CHOICES }
    end

    # Whole patches, in GitHub's order, until MAX_DIFF_BYTES is spent. A patch that doesn't fit is
    # left out rather than cut, so every file Jev answers for is one it read in full.
    def patches_within_budget(files)
      budget = MAX_DIFF_BYTES
      files.map do |file|
        next if file.patch.blank? || file.patch.bytesize > budget

        budget -= file.patch.bytesize
        file.patch
      end
    end

    def state_for(full_name, pull_request, files, patches)
      {
        repository: full_name,
        title: pull_request.title,
        description: pull_request.body.to_s.truncate(5_000),
        author: pull_request.author_login,
        base_branch: pull_request.base_ref,
        head_branch: pull_request.head_ref,
        stats: { additions: pull_request.additions, deletions: pull_request.deletions, changed_files: pull_request.changed_files },
        files: files.zip(patches).map do |file, patch|
          entry = { filename: file.filename, previous_filename: file.previous_filename, status: file.status,
                    additions: file.additions, deletions: file.deletions }.compact
          entry.merge(patch ? { patch: patch } : { patch_omitted: file.patch.present? ? "left out to fit the size limit" : "binary or no text diff" })
        end
      }
    end

    def decision_from(response, question_id)
      answer = response.answers&.dig(question_id)
      raise Jev::Client::Error, "Jev didn't answer the review question." unless answer

      choice = answer["choice"]
      raise Jev::Client::Error, "Jev answered with an unknown option: #{choice.inspect}." unless CHOICES.key?(choice)

      Decision.new(choice: choice, probabilities: answer["probabilities"].to_h, confidence: answer["confidence"], model: response.model)
    end

    # A missing or odd file answer leaves that one file without a verdict; the PR verdict still stands.
    def file_decision(response, index)
      decision_from(response, "#{FILE_QUESTION_PREFIX}#{index}")
    rescue Jev::Client::Error
      nil
    end
end
