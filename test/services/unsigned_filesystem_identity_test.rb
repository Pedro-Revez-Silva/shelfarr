# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261023120000_store_filesystem_identities_as_text")

class UnsignedFilesystemIdentityTest < ActiveSupport::TestCase
  # mergerfs hashes branch paths into unsigned 64-bit inodes. About half are
  # past the signed SQLite integer limit.
  MERGERFS_DEVICE = 11_990_157_055_112_524_987
  MERGERFS_INODE = 14_388_417_833_670_522_537

  setup do
    @output_root = Dir.mktmpdir("unsigned-direct-identity")
    @owned_root = Dir.mktmpdir("unsigned-owned-identity")
    @legacy_root = Dir.mktmpdir("unsigned-owned-source")
    SettingsService.set(:audiobook_output_path, @owned_root)

    @book = Book.create!(title: "Unsigned Identity", author: "Merger Author", book_type: :ebook)
    @request = Request.create!(book: @book, user: users(:one), status: :downloading)
    @download = @request.downloads.create!(
      name: "Unsigned Identity",
      status: :downloading,
      download_type: "direct"
    )
    @destination = File.join(@output_root, "Merger Author", "Unsigned Identity", "book.epub")
    @service = DirectDownloadFileService.new(
      download: @download,
      book: @book,
      output_root: @output_root,
      destination_path: @destination,
      book_path: File.dirname(@destination),
      kind: :file
    )

    @owned_book = Book.create!(title: "Unsigned Import", author: "Merger Author", book_type: :audiobook)
    @source = File.join(@legacy_root, "Merger Author - Unsigned Import.m4b")
    File.binwrite(@source, "durable audiobook bytes")
    @connection = OwnedLibraryConnection.create!
    @item = @connection.owned_library_items.create!(
      external_id: "B0UNSIGNED1",
      title: "Unsigned Import",
      authors: [ "Merger Author" ],
      ownership_type: "purchased"
    )
    @upload = Upload.create!(
      user: users(:two),
      book: @owned_book,
      original_filename: File.basename(@source),
      file_path: @source,
      file_size: File.size(@source),
      content_type: "audio/mp4",
      status: :processing
    )
    @media_import = @item.owned_media_imports.create!(
      requested_by: users(:two),
      upload: @upload,
      status: "processing"
    )
    OwnedMediaImportFileService.ensure_persistent_staging!(@media_import, @upload)
    @upload.reload
    @owned_service = OwnedMediaImportFileService.new(
      media_import: @media_import,
      upload: @upload,
      book: @owned_book
    )
  end

  teardown do
    FileUtils.rm_rf(@output_root)
    FileUtils.rm_rf(@owned_root)
    FileUtils.rm_rf(@legacy_root)
  end

  test "direct downloads and owned media imports keep device and inode identities above 2^63" do
    with_unsigned_stat(device: MERGERFS_DEVICE, inode: MERGERFS_INODE) do
      staging = @service.create_staging!
      @download.reload

      assert_equal MERGERFS_DEVICE, @download.direct_output_root_device
      assert_equal MERGERFS_INODE, @download.direct_output_root_inode
      assert_equal MERGERFS_DEVICE, @download.direct_staging_device
      assert_equal MERGERFS_INODE, @download.direct_staging_inode
      assert_equal MERGERFS_DEVICE, @download.direct_staging_parent_device
      assert_equal MERGERFS_INODE, @download.direct_staging_parent_inode
      assert_equal [ MERGERFS_DEVICE, MERGERFS_INODE ], [ File.lstat(staging).dev, File.lstat(staging).ino ]
      assert DirectDownloadFileService.send(:valid_output_root_identity?, @download)
      assert DirectDownloadFileService.send(:valid_staging_parent_identity?, @download)

      @owned_service.with_destination_lock { }
      @media_import.reload
      source_stat = File.lstat(@upload.file_path)

      assert_equal MERGERFS_DEVICE, @media_import.staged_device
      assert_equal MERGERFS_INODE, @media_import.staged_inode
      assert_equal [ source_stat.dev, source_stat.ino ], [ @media_import.staged_device, @media_import.staged_inode ]
      assert OwnedMediaImportFileService.send(:persisted_identity_matches?, @media_import, source_stat)
      assert_equal @upload.file_path, OwnedMediaImportFileService.recovery_source_path(@media_import, @upload)

      with_unsigned_stat(device: MERGERFS_DEVICE, inode: MERGERFS_INODE + 1) do
        shifted = File.lstat(@output_root)

        assert_not DirectDownloadFileService.send(:valid_output_root_identity?, @download)
        assert_not_equal [ shifted.dev, shifted.ino ], [
          @download.direct_output_root_device,
          @download.direct_output_root_inode
        ]
        assert_not OwnedMediaImportFileService.send(
          :persisted_identity_matches?,
          @media_import,
          File.lstat(@upload.file_path)
        )
      end
    end
  end

  test "migrated signed device and inode values still match fresh stat results" do
    legacy_device = 0
    legacy_inode = (2**63) - 1
    stored = migrate_legacy_identities(device: legacy_device, inode: legacy_inode)

    assert_equal legacy_device.to_s, stored.fetch(:device)
    assert_equal legacy_inode.to_s, stored.fetch(:inode)
    assert_equal "text", stored.fetch(:device_type)
    assert_equal "text", stored.fetch(:inode_type)
    assert_nil stored.fetch(:null_device)
    assert_equal "null", stored.fetch(:null_device_type)

    type = Shelfarr::FilesystemIdentityType.new
    assert_equal legacy_device, type.deserialize(stored.fetch(:device))
    assert_equal legacy_inode, type.deserialize(stored.fetch(:inode))
    assert_equal legacy_device, type.deserialize(legacy_device)
    assert_nil type.deserialize(nil)
    assert_equal "0", type.serialize(0)

    @service.create_staging!
    write_identity_text(@download, {
      direct_output_root_device: stored.fetch(:device),
      direct_output_root_inode: stored.fetch(:inode),
      direct_staging_device: stored.fetch(:device),
      direct_staging_inode: stored.fetch(:inode),
      direct_staging_parent_device: stored.fetch(:device),
      direct_staging_parent_inode: stored.fetch(:inode)
    })
    write_identity_text(@media_import, {
      staged_device: stored.fetch(:device),
      staged_inode: stored.fetch(:inode)
    })

    with_unsigned_stat(device: legacy_device, inode: legacy_inode) do
      assert_equal legacy_device, @download.direct_output_root_device
      assert_equal legacy_inode, @download.direct_output_root_inode
      assert_equal legacy_device, @download.direct_staging_device
      assert_equal legacy_inode, @download.direct_staging_parent_inode
      assert_equal [ File.lstat(@output_root).dev, File.lstat(@output_root).ino ], [
        @download.direct_output_root_device,
        @download.direct_output_root_inode
      ]
      assert DirectDownloadFileService.send(:valid_output_root_identity?, @download)
      assert DirectDownloadFileService.send(:valid_staging_parent_identity?, @download)

      source_stat = File.lstat(@upload.file_path)
      assert_equal legacy_device, @media_import.staged_device
      assert_equal legacy_inode, @media_import.staged_inode
      assert OwnedMediaImportFileService.send(:persisted_identity_matches?, @media_import, source_stat)
      assert_equal @upload.file_path, OwnedMediaImportFileService.recovery_source_path(@media_import, @upload)
    end
  end

  private

  def with_unsigned_stat(device:, inode:)
    prepend_unsigned_stat_identity
    previous_device = Thread.current[:unsigned_stat_device]
    previous_inode = Thread.current[:unsigned_stat_inode]
    Thread.current[:unsigned_stat_device] = device
    Thread.current[:unsigned_stat_inode] = inode
    yield
  ensure
    Thread.current[:unsigned_stat_device] = previous_device
    Thread.current[:unsigned_stat_inode] = previous_inode
  end

  def prepend_unsigned_stat_identity
    return if File::Stat <= UnsignedStatIdentity

    File::Stat.prepend(UnsignedStatIdentity)
  end

  def migrate_legacy_identities(device:, inode:)
    directory = Dir.mktmpdir("filesystem-identity-migration")
    database = File.join(directory, "scratch.sqlite3")
    LegacyIdentityRecord.establish_connection(adapter: "sqlite3", database: database)
    connection = LegacyIdentityRecord.connection
    assert_not_equal Download.connection.pool.db_config.database, connection.pool.db_config.database

    connection.create_table :downloads, force: true do |table|
      table.integer :direct_output_root_device
      table.integer :direct_output_root_inode
      table.integer :direct_staging_device
      table.integer :direct_staging_inode
      table.integer :direct_staging_parent_device
      table.integer :direct_staging_parent_inode
    end
    connection.create_table :owned_media_imports, force: true do |table|
      table.integer :staged_device
      table.integer :staged_inode
    end
    connection.execute(<<~SQL)
      INSERT INTO downloads (
        direct_output_root_device,
        direct_output_root_inode,
        direct_staging_device,
        direct_staging_inode,
        direct_staging_parent_device,
        direct_staging_parent_inode
      ) VALUES (
        #{device.to_i},
        #{inode.to_i},
        #{device.to_i},
        #{inode.to_i},
        #{device.to_i},
        #{inode.to_i}
      )
    SQL
    connection.execute("INSERT INTO downloads DEFAULT VALUES")
    connection.execute(<<~SQL)
      INSERT INTO owned_media_imports (staged_device, staged_inode)
      VALUES (#{device.to_i}, #{inode.to_i})
    SQL
    connection.execute("INSERT INTO owned_media_imports DEFAULT VALUES")

    migration = StoreFilesystemIdentitiesAsText.new
    migration.verbose = false
    migration.instance_variable_set(:@connection, connection)
    migration.up

    download = connection.select_one(<<~SQL)
      SELECT
        direct_output_root_device,
        typeof(direct_output_root_device) AS device_type,
        direct_output_root_inode,
        typeof(direct_output_root_inode) AS inode_type,
        direct_staging_device,
        typeof(direct_staging_device) AS staging_device_type,
        direct_staging_inode,
        typeof(direct_staging_inode) AS staging_inode_type,
        direct_staging_parent_device,
        typeof(direct_staging_parent_device) AS parent_device_type,
        direct_staging_parent_inode,
        typeof(direct_staging_parent_inode) AS parent_inode_type
      FROM downloads
      WHERE direct_output_root_inode IS NOT NULL
    SQL
    blank = connection.select_one(<<~SQL)
      SELECT
        direct_output_root_device,
        typeof(direct_output_root_device) AS device_type,
        direct_staging_parent_inode,
        typeof(direct_staging_parent_inode) AS parent_inode_type
      FROM downloads
      WHERE direct_output_root_inode IS NULL
    SQL
    imported = connection.select_one(<<~SQL)
      SELECT staged_device, typeof(staged_device) AS device_type,
             staged_inode, typeof(staged_inode) AS inode_type
      FROM owned_media_imports
      WHERE staged_inode IS NOT NULL
    SQL

    assert_equal device.to_s, download.fetch("direct_staging_device")
    assert_equal inode.to_s, download.fetch("direct_staging_inode")
    assert_equal device.to_s, download.fetch("direct_staging_parent_device")
    assert_equal inode.to_s, download.fetch("direct_staging_parent_inode")
    assert_equal "text", download.fetch("staging_device_type")
    assert_equal "text", download.fetch("staging_inode_type")
    assert_equal "text", download.fetch("parent_device_type")
    assert_equal "text", download.fetch("parent_inode_type")
    assert_nil blank.fetch("direct_output_root_device")
    assert_nil blank.fetch("direct_staging_parent_inode")
    assert_equal "null", blank.fetch("device_type")
    assert_equal "null", blank.fetch("parent_inode_type")
    assert_equal device.to_s, imported.fetch("staged_device")
    assert_equal inode.to_s, imported.fetch("staged_inode")
    assert_equal "text", imported.fetch("device_type")
    assert_equal "text", imported.fetch("inode_type")

    migration.down
    reverted = connection.select_one(<<~SQL)
      SELECT
        direct_output_root_device,
        typeof(direct_output_root_device) AS device_type,
        direct_output_root_inode,
        typeof(direct_output_root_inode) AS inode_type
      FROM downloads
      WHERE direct_output_root_inode IS NOT NULL
    SQL
    reverted_import = connection.select_one(<<~SQL)
      SELECT staged_device, typeof(staged_device) AS device_type,
             staged_inode, typeof(staged_inode) AS inode_type
      FROM owned_media_imports
      WHERE staged_inode IS NOT NULL
    SQL
    assert_equal device, Integer(reverted.fetch("direct_output_root_device").to_s, 10)
    assert_equal inode, Integer(reverted.fetch("direct_output_root_inode").to_s, 10)
    assert_equal "integer", reverted.fetch("device_type")
    assert_equal "integer", reverted.fetch("inode_type")
    assert_equal device, Integer(reverted_import.fetch("staged_device").to_s, 10)
    assert_equal inode, Integer(reverted_import.fetch("staged_inode").to_s, 10)
    assert_equal "integer", reverted_import.fetch("device_type")
    assert_equal "integer", reverted_import.fetch("inode_type")

    {
      device: download.fetch("direct_output_root_device"),
      inode: download.fetch("direct_output_root_inode"),
      device_type: download.fetch("device_type"),
      inode_type: download.fetch("inode_type"),
      null_device: blank.fetch("direct_output_root_device"),
      null_device_type: blank.fetch("device_type")
    }
  ensure
    release_legacy_identity_connection
    FileUtils.rm_rf(directory) if directory
  end

  def release_legacy_identity_connection
    # Transactional tests pin every connection opened during the example.
    # Drop the scratch database before its file is removed.
    return unless defined?(LegacyIdentityRecord)
    return unless LegacyIdentityRecord.connected?

    pool = LegacyIdentityRecord.connection_pool
    @fixture_connection_pools&.delete(pool)
    name = LegacyIdentityRecord.connection_specification_name
    pool.disconnect!
    ActiveRecord::Base.connection_handler.remove_connection_pool(name)
  end

  def write_identity_text(record, attributes)
    connection = record.class.connection
    assignments = attributes.map do |column, value|
      "#{connection.quote_column_name(column)} = #{connection.quote(value)}"
    end
    connection.execute(<<~SQL.squish)
      UPDATE #{connection.quote_table_name(record.class.table_name)}
      SET #{assignments.join(", ")}
      WHERE #{connection.quote_column_name(record.class.primary_key)} = #{record.id.to_i}
    SQL
    record.reload
  end

  class LegacyIdentityRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  module UnsignedStatIdentity
    def dev
      override = Thread.current[:unsigned_stat_device]
      override.nil? ? super : override
    end

    def ino
      override = Thread.current[:unsigned_stat_inode]
      override.nil? ? super : override
    end
  end
  private_constant :UnsignedStatIdentity
end
