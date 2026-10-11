# Jev's verdict for a diff sent without a GitHub pull request (see DiffPayload), kept in the cache by the
# diff's hash so the same diff sent again is answered for free. Only file names and verdicts are kept, never patches.
DiffVerdict = Data.define(:diff_sha256, :choice, :probabilities, :confidence, :model, :files, :diff_truncated) do
  self::TTL = 7.days
  # The API's names for PrAssessment::VERDICTS.
  self::NAMES = { "yes" => "human", "llm_enough" => "llm", "no" => "none" }.freeze

  def self.find(diff_sha256)
    attributes = Rails.cache.read(cache_key(diff_sha256))
    new(**attributes.symbolize_keys) if attributes
  end

  def self.record!(diff_sha256, result)
    decision = result.decision
    verdict = new(diff_sha256: diff_sha256, choice: decision.choice, probabilities: decision.probabilities, confidence: decision.confidence,
                  model: decision.model, files: result.files.map { |file| PrAssessment.file_entry(file).slice("filename", "choice", "skipped") },
                  diff_truncated: result.diff_truncated)
    Rails.cache.write(cache_key(diff_sha256), verdict.to_h, expires_in: self::TTL)
    verdict
  end

  def self.cache_key(diff_sha256) = [ "diff_verdicts/v1", diff_sha256 ]

  # The API response, minus the link.
  def as_json(*)
    { verdict: self.class::NAMES.fetch(choice), confidence: confidence,
      files: files.map do |file|
        { filename: file["filename"], verdict: self.class::NAMES[file["choice"]] }.merge(file["skipped"] ? { skipped: file["skipped"] } : {})
      end,
      diff_truncated: diff_truncated }
  end
end
