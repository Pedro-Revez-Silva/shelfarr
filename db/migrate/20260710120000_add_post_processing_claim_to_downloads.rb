# frozen_string_literal: true

class AddPostProcessingClaimToDownloads < ActiveRecord::Migration[8.1]
  def change
    add_column :downloads, :post_processing_job_id, :string
  end
end
