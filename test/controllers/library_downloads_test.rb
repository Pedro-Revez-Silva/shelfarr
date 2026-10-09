# frozen_string_literal: true

require "test_helper"
require "zip"

class LibraryDownloadsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @root = Dir.mktmpdir("library-downloads")
    SettingsService.set(:ebook_output_path, @root)
    @path = File.join(@root, "Uploaded.epub")
    File.binwrite(@path, "uploaded ebook bytes")
    @book = Book.create!(title: "Uploaded", author: "Author", book_type: :ebook, file_path: @path)
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "upload-only book has a download link without creating a request" do
    assert_no_difference "Request.count" do
      get library_path(@book)
    end
    assert_response :success
    assert_select "a[href='/library/#{@book.id}/download']", text: /Download/
    assert_select "body", text: /no associated download request/, count: 0
  end

  test "signed-in user downloads upload-only bytes without request provenance" do
    assert_no_difference "Request.count" do
      get "/library/#{@book.id}/download"
    end
    assert_response :success
    assert_equal "uploaded ebook bytes", response.body
    assert_includes response.headers["Content-Disposition"], "attachment"
  end

  test "download requires authentication" do
    sign_out
    get "/library/#{@book.id}/download"
    assert_response :redirect
  end

  test "unacquired books are unavailable" do
    @book.update!(file_path: nil)
    get "/library/#{@book.id}/download"
    assert_response :not_found
  end

  test "missing file redirects back to library details" do
    File.unlink(@path)
    get "/library/#{@book.id}/download"
    assert_redirected_to library_path(@book)
    assert_equal "File not found on server", flash[:alert]
  end

  test "configured roots do not authorize a sibling path" do
    sibling = Dir.mktmpdir("library-downloads-outside")
    outside = File.join(sibling, "private.epub")
    File.binwrite(outside, "private bytes")
    @book.update!(file_path: outside)
    get "/library/#{@book.id}/download"
    assert_redirected_to library_path(@book)
    assert_equal "Invalid file path", flash[:alert]
    assert_not_includes response.body, "private bytes"
  ensure
    FileUtils.remove_entry(sibling) if sibling
  end

  test "upload-only directories are zipped with original content and UTF-8 filenames" do
    directory = File.join(@root, "book")
    FileUtils.mkdir_p(directory)
    File.binwrite(File.join(directory, "Überblick.epub"), "German bytes")
    @book.update!(file_path: directory)
    get "/library/#{@book.id}/download"
    assert_response :success
    assert_equal "application/zip", response.media_type
    Zip::InputStream.open(StringIO.new(response.body)) do |zip|
      entry = zip.get_next_entry
      assert_equal "Überblick.epub".b, entry.name.b
      assert_equal 0x0800, entry.gp_flags & 0x0800
      assert_equal "German bytes", zip.read
      assert_nil zip.get_next_entry
    end
  end

  test "the entire library root cannot be bundled" do
    @book.update!(file_path: @root)
    get "/library/#{@book.id}/download"
    assert_redirected_to library_path(@book)
    assert_includes flash[:alert], "cannot be downloaded as a bundle"
  end
end
