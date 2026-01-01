class AddLanguageToRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :requests, :language, :string
  end
end
