class AddObservedAtToConsumerProgresses < ActiveRecord::Migration[8.1]
  # The device-reported time a checkpoint was observed. Existing rows keep NULL:
  # their activity time is unknown, and updated_at only records server receipt.
  def change
    add_column :consumer_progresses, :observed_at, :datetime
  end
end
