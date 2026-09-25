require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "short_time_ago keeps dense lists on one line" do
    now = Time.zone.parse("2026-09-26 12:00")

    assert_equal "just now", short_time_ago(now - 20.seconds, now: now)
    assert_equal "5m ago", short_time_ago(now - 5.minutes, now: now)
    assert_equal "3h ago", short_time_ago(now - 3.hours - 10.minutes, now: now)
    assert_equal "4d ago", short_time_ago(now - 4.days, now: now)
    assert_equal "Mar 2", short_time_ago(Time.zone.parse("2026-03-02 09:00"), now: now)
    assert_equal "Mar 2023", short_time_ago(Time.zone.parse("2023-03-02 09:00"), now: now)
  end
end
