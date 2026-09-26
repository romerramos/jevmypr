# Whether a user may ask Jev for a new verdict right now, and if not, why and until when.
# Checks, in order: GitHub account age (bot filter), the user's weekly quota, and the app's
# monthly budget. Re-reading saved verdicts never goes through here. Limits: config/initializers/jev_limits.rb
class JevAllowance
  Denial = Data.define(:reason, :message)

  def initialize(user, now: Time.current, limits: Rails.configuration.x.jev_limits)
    @user = user
    @now = now
    @limits = limits
  end

  def denial
    account_too_new || weekly_quota_used || monthly_budget_spent
  end

  def allowed? = denial.nil?

  def weekly_limit = @limits.weekly_verdicts_per_user
  def weekly_used = weekly_verdicts.count
  def weekly_remaining = [ weekly_limit - weekly_used, 0 ].max

  # Estimated spend this calendar month across all users, from the token counts Jev reports.
  def monthly_spend_usd
    tokens = PrAssessment.where(created_at: @now.beginning_of_month..).pick(Arel.sql("SUM(input_tokens), SUM(output_tokens)"))
    input, output = tokens.map(&:to_i)
    (input * @limits.usd_per_million_input_tokens + output * @limits.usd_per_million_output_tokens) / 1_000_000.0
  end

  private
    def weekly_verdicts = @user.pr_assessments.where(created_at: (@now - 7.days)..)

    def account_too_new
      created = @user.github_created_at
      return if created.nil? || created <= @now - @limits.min_github_account_age

      opens_on = (created + @limits.min_github_account_age).to_date
      Denial.new(:account_too_new, "To keep bots out, asking Jev needs a GitHub account that's at least " \
                                   "#{@limits.min_github_account_age.inspect} old. Yours will be on #{long_date(opens_on)}.")
    end

    def weekly_quota_used
      return if weekly_used < weekly_limit

      frees_up = weekly_verdicts.minimum(:created_at) + 7.days
      Denial.new(:weekly_quota, "You've used all #{weekly_limit} verdicts for this week. The next one frees up " \
                                "in #{ActionController::Base.helpers.distance_of_time_in_words(@now, frees_up)}. " \
                                "Your saved verdicts are still here.")
    end

    def monthly_budget_spent
      return if monthly_spend_usd < @limits.monthly_budget_usd

      Denial.new(:monthly_budget, "Jev's budget for this month is spent, so new verdicts are paused until " \
                                  "#{long_date(@now.next_month.beginning_of_month)}. Saved verdicts are still here.")
    end

    def long_date(date) = date.strftime("%B %-d, %Y")
end
