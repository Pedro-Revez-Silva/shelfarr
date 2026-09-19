require "test_helper"

class CollectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
    @collection = BookCollection.create!(source: "hardcover", source_id: "100", title: "A Test Series")
    @work = BookWork.create!(source: "hardcover", source_id: "101", title: "The First Book", author: "An Author")
    @membership = @collection.collection_memberships.create!(book_work: @work, position: "1", sort_order: 0)
  end

  test "collection reads and writes require authentication" do
    sign_out

    get collections_path
    assert_redirected_to new_session_path
    get collection_path(@collection)
    assert_redirected_to new_session_path
    post collections_path, params: { source_id: "100" }
    assert_redirected_to new_session_path
    post request_books_collection_path(@collection), params: { whole_series: "1", book_types: [ "ebook" ] }
    assert_redirected_to new_session_path
  end

  test "index lists saved collections and both navigation links" do
    get collections_path

    assert_response :success
    assert_select "h1", "Collections"
    assert_select "a[href=?] h2", collection_path(@collection), text: "A Test Series"
    assert_select "nav a[href=?]", collections_path, text: "Collections", count: 2
    assert_select "label[for=source_id]", "Hardcover series ID"
  end

  test "adding a series uses only its provider ID and opens the saved collection" do
    imported_id = nil
    importer = ->(source_id:) { imported_id = source_id; @collection }

    BookCollectionImportService.stub(:call, importer) do
      post collections_path, params: { source_id: "100", title: "Untrusted title", source: "other" }
    end

    assert_equal "100", imported_id
    assert_redirected_to collection_path(@collection)
    assert_response :see_other
  end

  test "invalid series identifiers never reach the importer" do
    BookCollectionImportService.stub(:call, ->(**) { flunk "Invalid provider ID reached import" }) do
      [ "0", "-1", "100junk", "https://hardcover.app/series/100", "1" * 20, [ "100" ] ].each do |source_id|
        post collections_path, params: { source_id: source_id }

        assert_response :unprocessable_entity
        assert_select "[role=alert]", text: /valid Hardcover series ID/
      end
    end
  end

  test "provider failures keep the entered ID and explain the error" do
    BookCollectionImportService.stub(:call, ->(**) { raise BookCollectionImportService::Error, "Hardcover is temporarily unavailable." }) do
      post collections_path, params: { source_id: "100" }
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Hardcover is temporarily unavailable/
    assert_select "input[name=source_id][value='100']"
  end

  test "an import save conflict does not expose database details" do
    BookCollectionImportService.stub(:call, ->(**) { raise ActiveRecord::RecordNotUnique, "Private database query" }) do
      post collections_path, params: { source_id: "100" }
    end

    assert_response :conflict
    assert_select "[role=alert]", text: /could not be saved right now/
    assert_no_match "Private database query", response.body
  end

  test "show renders one work row with separate format availability and ebook default" do
    @work.books.create!(title: @work.title, book_type: :ebook, file_path: "/library/first.epub")
    @work.books.create!(title: @work.title, book_type: :ebook, file_path: "/library/another-edition.epub")
    audio = @work.books.create!(title: @work.title, book_type: :audiobook)
    audio.requests.create!(user: users(:two), status: :downloading)

    get collection_path(@collection)

    assert_response :success
    assert_select "article[data-collection-membership]", count: 1
    assert_select "[data-format=ebook] dd", "In library"
    assert_select "[data-format=audiobook] dd", "Downloading"
    assert_select "input[name='book_types[]'][value=ebook][checked]"
    assert_select "input[name='book_types[]'][value=audiobook]:not([checked])"
    assert_select "input[name=whole_series][type=checkbox][checked]"
    assert_select "select[name=language] option[value=en][selected]", "English"
    assert_select "a[href=?]", request_path(audio.requests.first), count: 0
  end

  test "ambiguous membership is visible and not preselected" do
    @membership.update!(ambiguous: true)

    get collection_path(@collection)

    assert_response :success
    assert_select "article p", text: /Needs review/
    assert_select "input[name='membership_ids[]'][value='#{@membership.id}']:not([checked])"
  end

  test "both formats are passed to collection request service under current user" do
    received = nil
    result = BookCollectionRequestService::Result.new(created_requests: [ Object.new, Object.new ], skipped: [], errors: [])
    service = ->(**args) { received = args; result }

    BookCollectionRequestService.stub(:call, service) do
      post request_books_collection_path(@collection), params: {
        whole_series: "1", book_types: %w[ebook audiobook], language: "en", user_id: users(:two).id
      }
    end

    assert_redirected_to collection_path(@collection)
    assert_equal @collection, received[:collection]
    assert_equal @user, received[:user]
    assert_equal %w[ebook audiobook], received[:book_types]
    assert_equal true, received[:whole_series]
    assert_equal [], received[:membership_ids]
    assert_equal "en", received[:language]
    assert_equal "2 requests created.", flash[:notice]
  end

  test "individual selection is preserved when requesting books" do
    received = nil
    result = BookCollectionRequestService::Result.new(created_requests: [], skipped: [ "Already requested" ], errors: [])

    BookCollectionRequestService.stub(:call, ->(**args) { received = args; result }) do
      post request_books_collection_path(@collection), params: {
        whole_series: "0", book_types: [ "audiobook" ], membership_ids: [ @membership.id.to_s ]
      }
    end

    assert_redirected_to collection_path(@collection)
    assert_equal false, received[:whole_series]
    assert_equal [ @membership.id.to_s ], received[:membership_ids]
    assert_equal "0 requests created. 1 skipped.", flash[:notice]
  end

  test "zero formats and unknown formats fail before creating requests" do
    BookCollectionRequestService.stub(:call, ->(**) { flunk "Invalid formats reached request service" }) do
      post request_books_collection_path(@collection), params: { whole_series: "1" }
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: /Select ebooks, audiobooks, or both/
      assert_select "input[name='book_types[]'][checked]", count: 0

      post request_books_collection_path(@collection), params: { whole_series: "1", book_types: [ "ebook", "comicbook" ] }
      assert_response :unprocessable_entity
      assert_select "[role=alert]", text: /Select only ebooks and audiobooks/
    end
  end

  test "request mode must be explicit" do
    BookCollectionRequestService.stub(:call, ->(**) { flunk "Invalid selection mode reached request service" }) do
      post request_books_collection_path(@collection), params: { book_types: [ "ebook" ], membership_ids: [ @membership.id.to_s ] }
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Choose the whole series or individual books/
  end

  test "malformed selection payloads are rejected" do
    BookCollectionRequestService.stub(:call, ->(**) { flunk "Malformed payload reached request service" }) do
      post request_books_collection_path(@collection), params: { whole_series: "1", book_types: "ebook" }
      assert_response :bad_request
      post request_books_collection_path(@collection), params: { whole_series: "0", book_types: [ "ebook" ], membership_ids: { id: @membership.id } }
      assert_response :bad_request
    end
  end

  test "partial failures retain selections and disclose created and skipped requests" do
    result = BookCollectionRequestService::Result.new(created_requests: [ Object.new ], skipped: [ "Already owned" ], errors: [ "The second book could not be requested." ])

    BookCollectionRequestService.stub(:call, result) do
      post request_books_collection_path(@collection), params: {
        whole_series: "0", book_types: [ "audiobook" ], membership_ids: [ @membership.id.to_s ]
      }
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /The second book could not be requested/
    assert_select "input[name='book_types[]'][value=audiobook][checked]"
    assert_select "input[name='membership_ids[]'][value='#{@membership.id}'][checked]"
    assert_select "input[name=whole_series][type=checkbox]:not([checked])"
    assert_equal "1 request created. 1 skipped.", flash[:notice]
  end

  test "missing collection has a useful destination" do
    get collection_path(id: 0)

    assert_redirected_to collections_path
    assert_equal "Collection not found.", flash[:alert]
  end
end
