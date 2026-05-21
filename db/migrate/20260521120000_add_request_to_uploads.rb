# frozen_string_literal: true

class AddRequestToUploads < ActiveRecord::Migration[8.0]
  def change
    add_reference :uploads, :request, foreign_key: true
  end
end
