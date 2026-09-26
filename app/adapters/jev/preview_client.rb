module Jev
  # Same ask interface as Client, answered from the sample pull request number.
  # Usage is zero so a preview session never spends the monthly budget.
  class PreviewClient
    def ask(state:, questions:, model: Client::DEFAULT_MODEL)
      DevelopmentPreview.jev_response(state[:number])
    end
  end
end
