require "test_helper"

class JevAllowanceTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @user.update!(github_created_at: 2.years.ago)
    @now = Time.zone.parse("2026-09-26 12:00")
  end

  test "allows a user with quota left, an established account and budget remaining" do
    allowance = JevAllowance.new(@user, now: @now)

    assert allowance.allowed?
    assert_equal 100, allowance.weekly_remaining
  end

  test "counts verdicts in the last 7 days against the weekly quota" do
    99.times { |i| verdict(@user, at: @now - 1.day, number: i) }
    verdict(@user, at: @now - 8.days, number: 500) # outside the window

    allowance = JevAllowance.new(@user, now: @now)
    assert_equal 1, allowance.weekly_remaining
    assert allowance.allowed?

    verdict(@user, at: @now - 6.days, number: 501)
    denial = JevAllowance.new(@user, now: @now).denial
    assert_equal :weekly_quota, denial.reason
    assert_match "next one frees up in 1 day", denial.message # the oldest one in the window is 6 days old
  end

  test "blocks GitHub accounts younger than 30 days, but not unknown or older ones" do
    @user.update!(github_created_at: @now - 10.days)
    denial = JevAllowance.new(@user, now: @now).denial
    assert_equal :account_too_new, denial.reason
    assert_match "October 16, 2026", denial.message

    @user.update!(github_created_at: nil)
    assert JevAllowance.new(@user, now: @now).allowed?
  end

  test "pauses everyone once the month's estimated spend reaches the budget" do
    limits = Rails.configuration.x.jev_limits.dup.merge!(monthly_budget_usd: 0.001)
    verdict(users(:two), at: @now.beginning_of_month + 1.hour, number: 1, input_tokens: 20_000, output_tokens: 40) # ~$0.00084
    assert JevAllowance.new(@user, now: @now, limits: limits).allowed?

    verdict(users(:two), at: @now - 1.hour, number: 2, input_tokens: 10_000) # last month's usage doesn't count, this does
    verdict(users(:two), at: @now.beginning_of_month - 1.hour, number: 3, input_tokens: 10_000_000)
    denial = JevAllowance.new(@user, now: @now, limits: limits).denial
    assert_equal :monthly_budget, denial.reason
    assert_match "paused until October 1, 2026", denial.message
  end

  test "estimates spend from Jev's token counts" do
    verdict(@user, at: @now - 1.hour, number: 1, input_tokens: 1_000_000, output_tokens: 1_000_000)

    assert_in_delta 0.084, JevAllowance.new(@user, now: @now).monthly_spend_usd, 1e-9
  end

  private
    def verdict(user, at:, number:, input_tokens: 0, output_tokens: 0)
      user.pr_assessments.create!(repo_full_name: "acme/web", pr_number: number, pr_title: "PR #{number}", choice: "no",
                                  pr_url: "https://github.com/acme/web/pull/#{number}", created_at: at,
                                  input_tokens: input_tokens, output_tokens: output_tokens)
    end
end
