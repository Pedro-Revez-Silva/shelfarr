# frozen_string_literal: true

class AddLoginSecurityToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :failed_login_count, :integer, default: 0, null: false
    add_column :users, :locked_until, :datetime
    add_column :users, :last_failed_login_at, :datetime
    add_column :users, :last_failed_login_ip, :string

    # For 2FA support
    add_column :users, :otp_secret, :string
    add_column :users, :otp_required, :boolean, default: false, null: false
  end
end
