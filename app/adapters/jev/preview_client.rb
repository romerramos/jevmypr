module Jev
  # Same ask interface as Client, answered from DevelopmentPreview's sample verdicts.
  # Usage is zero so a preview session never spends the monthly budget.
  class PreviewClient
    def ask(state:, questions:, model: Client::DEFAULT_MODEL)
      DevelopmentPreview.jev_response(state: state, questions: questions)
    end
  end
end
