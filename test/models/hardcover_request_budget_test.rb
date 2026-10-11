# frozen_string_literal: true

require "test_helper"

class HardcoverRequestBudgetTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:hardcover_max_requests_per_run, 3)
    SettingsService.set(:hardcover_sync_interval_hours, 4)
    @user = users(:one)
  end

  test "a window lasts one check interval and then starts over" do
    budget = HardcoverRequestBudget.current_for!(@user)
    budget.consume!(3)
    assert_equal 0, budget.remaining
    assert_equal [ @user.id ], HardcoverRequestBudget.exhausted.pluck(:user_id)

    travel 3.hours do
      assert_equal 0, HardcoverRequestBudget.current_for!(@user).remaining
    end

    travel 4.hours + 1.second do
      assert_empty HardcoverRequestBudget.exhausted.pluck(:user_id)
      renewed = HardcoverRequestBudget.current_for!(@user)
      assert_equal [ 3, Time.current.to_i ], [ renewed.remaining, renewed.window_started_at.to_i ]
    end
  end

  test "a lower limit leaves nothing rather than a negative count" do
    budget = HardcoverRequestBudget.current_for!(@user)
    budget.consume!(3)
    SettingsService.set(:hardcover_max_requests_per_run, 1)

    assert_equal 0, budget.reload.remaining
    assert_equal [ @user.id ], HardcoverRequestBudget.exhausted.pluck(:user_id)
  end
end
