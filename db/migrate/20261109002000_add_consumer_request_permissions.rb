class AddConsumerRequestPermissions < ActiveRecord::Migration[8.1]
  # Native apps may opt in to requesting. A grant records exactly which scopes
  # the person was asked to approve (NULL: the original read/listen pair) and,
  # for an upgrade, which existing app credential it replaces. Tokens record
  # that they came from device approval, so they never act as admin tokens.
  def change
    add_column :consumer_device_grants, :scopes, :text
    add_column :consumer_device_grants, :replaces_api_token_id, :integer
    add_column :api_tokens, :issued_via, :string
    add_column :api_tokens, :replaces_api_token_id, :integer
  end
end
