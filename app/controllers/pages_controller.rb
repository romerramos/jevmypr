class PagesController < ApplicationController
  VERDICTS = %w[yes llm_enough no].freeze

  def home
    # Phase 1 preview of the torn-tag state, e.g. /?verdict=llm_enough. Removed once real verdicts exist.
    if VERDICTS.include?(params[:verdict])
      @preview_verdict = params[:verdict]
      @preview_fields = { repo: "romerramos/jev-my-pr", pr: "#42", title: "Add GitHub sign-in" }
    end
  end
end
