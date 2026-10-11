# Whether a user may ask Jev for a new verdict right now, and if not, why and until when.
# Checks, in order: GitHub account age (bot filter), the user's weekly quota, and the app's
# monthly budget. Re-reading saved verdicts never goes through here.
# Anonymous callers (the open API, user nil, identified by a hash of their IP address) go through a daily
# cap per IP, the API's share of the monthly budget and the monthly budget itself.
class JevAllowance
  # retry_at: when asking again can work.
  Denial = Data.define(:reason, :message, :retry_at)

  # The limits that keep Jev my PR free to use and within its monthly budget. Tune them here.
  # Jev's price is $42 per billion input tokens (typesafe.ai); output pricing isn't published and each
  # call returns only a few dozen output tokens, so they're priced like input to stay on the safe side.
  LIMITS = Data.define(:weekly_verdicts_per_user, :asks_per_minute_per_user, :min_github_account_age,
                       :monthly_budget_usd, :usd_per_million_input_tokens, :usd_per_million_output_tokens,
                       :api_calls_per_ip, :api_calls_window, :api_daily_verdicts_per_ip, :api_budget_share).new(
    weekly_verdicts_per_user: 30,      # about 6 per workday; re-reading a saved verdict is free
    asks_per_minute_per_user: 5,       # stops scripts and double-click storms
    min_github_account_age: 30.days,   # throwaway bot accounts can browse but not ask Jev
    monthly_budget_usd: 18.0,          # pauses new verdicts for everyone until the 1st
    usd_per_million_input_tokens: 0.042,
    usd_per_million_output_tokens: 0.042,
    api_calls_per_ip: 1,               # the open API: 1 call per IP address every 2 minutes,
    api_calls_window: 2.minutes,       # counting every call, reused verdicts too
    api_daily_verdicts_per_ip: 10,     # new API verdicts per IP address in any 24 hours
    api_budget_share: 0.25             # the API pauses at a quarter of the monthly budget; signed-in use carries on
  )

  def initialize(user, ip_digest: nil, now: Time.current, limits: LIMITS)
    raise ArgumentError, "Anonymous callers need an ip_digest." if user.nil? && ip_digest.blank?

    @user = user
    @ip_digest = ip_digest
    @now = now
    @limits = limits
  end

  def denial
    return api_daily_quota_used || api_budget_spent || monthly_budget_spent if @user.nil?

    account_too_new || weekly_quota_used || monthly_budget_spent
  end

  def allowed? = denial.nil?

  def weekly_limit = @limits.weekly_verdicts_per_user
  def weekly_used = weekly_verdicts.count
  def weekly_remaining = [ weekly_limit - weekly_used, 0 ].max

  # Estimated spend this calendar month across all users (or one source of requests), from the token counts Jev reports.
  def monthly_spend_usd(requests = JevRequest.all)
    tokens = requests.where(sent_at: @now.beginning_of_month..@now).pick(Arel.sql("SUM(input_tokens), SUM(output_tokens)"))
    input, output = tokens.map(&:to_i)
    (input * @limits.usd_per_million_input_tokens + output * @limits.usd_per_million_output_tokens) / 1_000_000.0
  end

  private
    def weekly_verdicts = @user.jev_requests.chargeable(@now).where(created_at: (@now - 7.days)..@now)

    def account_too_new
      created = @user.github_created_at
      return if created.nil? || created <= @now - @limits.min_github_account_age

      opens_at = created + @limits.min_github_account_age
      Denial.new(:account_too_new, "To keep bots out, asking Jev needs a GitHub account that's at least " \
                                   "#{@limits.min_github_account_age.inspect} old. Yours will be on #{long_date(opens_at.to_date)}.", opens_at)
    end

    def weekly_quota_used
      return if weekly_used < weekly_limit

      frees_up = weekly_verdicts.minimum(:created_at) + 7.days
      Denial.new(:weekly_quota, "You've used all #{weekly_limit} verdicts for this week. The next one frees up " \
                                "in #{ActionController::Base.helpers.distance_of_time_in_words(@now, frees_up)}. " \
                                "Your saved verdicts are still here.", frees_up)
    end

    def monthly_budget_spent
      return if monthly_spend_usd < @limits.monthly_budget_usd

      resumes_at = @now.next_month.beginning_of_month
      Denial.new(:monthly_budget, "Jev's budget for this month is spent, so new verdicts are paused until " \
                                  "#{long_date(resumes_at)}. Saved verdicts are still here.", resumes_at)
    end

    def api_daily_verdicts = JevRequest.from_api.chargeable(@now).where(ip_digest: @ip_digest, created_at: (@now - 1.day)..@now)

    def api_daily_quota_used
      return if api_daily_verdicts.count < @limits.api_daily_verdicts_per_ip

      frees_up = api_daily_verdicts.minimum(:created_at) + 1.day
      Denial.new(:api_daily_quota, "This IP address has used all #{@limits.api_daily_verdicts_per_ip} new verdicts for today. " \
                                   "The next one frees up in #{ActionController::Base.helpers.distance_of_time_in_words(@now, frees_up)}. " \
                                   "Diffs that already have a verdict still get it.", frees_up)
    end

    def api_budget_spent
      return if monthly_spend_usd(JevRequest.from_api) < @limits.monthly_budget_usd * @limits.api_budget_share

      resumes_at = @now.next_month.beginning_of_month
      Denial.new(:api_budget, "The API's share of Jev's budget for this month is spent, so new API verdicts are paused " \
                              "until #{long_date(resumes_at)}. Diffs that already have a verdict still get it.", resumes_at)
    end

    def long_date(date) = date.strftime("%B %-d, %Y")
end
