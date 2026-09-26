# Limits that keep Jev my PR free to use and within its monthly budget.
# Jev's price is $42 per billion input tokens (typesafe.ai); output pricing isn't published and each
# call returns only a few dozen output tokens, so they're priced like input to stay on the safe side.
Rails.application.config.x.jev_limits = ActiveSupport::OrderedOptions.new.merge!(
  weekly_verdicts_per_user: 100,      # re-reading a saved verdict is free
  asks_per_minute_per_user: 5,        # stops scripts and double-click storms
  min_github_account_age: 30.days,    # throwaway bot accounts can browse but not ask Jev
  monthly_budget_usd: 18.0,           # pauses new verdicts for everyone until the 1st
  usd_per_million_input_tokens: 0.042,
  usd_per_million_output_tokens: 0.042
)
