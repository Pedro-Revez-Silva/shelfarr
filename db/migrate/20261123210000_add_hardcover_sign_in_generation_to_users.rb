class AddHardcoverSignInGenerationToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :hardcover_sign_in_generation, :integer, default: 0, null: false
  end
end
