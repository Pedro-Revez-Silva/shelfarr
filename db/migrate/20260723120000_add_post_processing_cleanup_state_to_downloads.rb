class AddPostProcessingCleanupStateToDownloads < ActiveRecord::Migration[8.1]
  def change
    add_column :downloads, :post_processing_cleanup_state, :text
  end
end
