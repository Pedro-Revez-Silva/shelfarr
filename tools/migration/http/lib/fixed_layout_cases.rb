# frozen_string_literal: true

require "json"
require_relative "../../lib/fixed_layout_media"

module Migration
  module Http
    module FixedLayoutCases
      FORMAT_SELECTIONS = [ "epub", "pdf", "cbz", "epub,pdf", "cbz,epub", "pdf, cbz", "cbz,pdf,epub", "pdf,pdf", " epub , pdf ", "epub,cbz,epub" ].freeze
      INVALID_SELECTIONS = { "uppercase" => "PDF", "trailing-comma" => "pdf,", "leading-comma" => ",pdf", "double-comma" => "pdf,,cbz", "empty" => "", "unknown" => "pdf,mobi", "semicolon" => "pdf;cbz", "tab-padded" => "\tpdf\t", "too-long" => "pdf," * 20 }.freeze
      PDF_LOCATOR = { "href" => "document.pdf", "type" => "application/pdf", "locations" => { "position" => 3 } }.freeze
      FIXED_KEYS = %w[fx-pdf fx-pdf-unicode fx-pdf-late fx-pdf-comic fx-pdf-graphic fx-comic fx-comic-ebook fx-comic-stored fx-comic-big fx-series fx-mixed].freeze

      def seed_fixed_layout_library
        root = @paths.media
        stamp = Time.at(1_700_300_000, 321, :nsec)
        pdf_bytes = ->(seed, size) { "%PDF-1.7\n".b + deterministic_bytes(seed, size) }
        fixed_book("fx-pdf", "FX Pdf", :ebook, write_bytes(File.join(root, "fx-pdf.pdf"), pdf_bytes.call(70, 300 * 1024 + 11), stamp), author: "P. Document")
        fixed_book("fx-pdf-unicode", "FX Pdf Unicode", :ebook, write_bytes(File.join(root, "Café ☕ \"Fixed\".pdf"), pdf_bytes.call(71, 4096), stamp + 1), author: "U. Name")
        fixed_book("fx-pdf-late", "FX Pdf Late Header", :ebook, write_bytes(File.join(root, "fx-pdf-late.pdf"), "junk\n".b * 200 + "%PDF-1.4\n".b + "x".b * 600, stamp + 2))
        fixed_book("fx-pdf-early", "FX Pdf Header Too Late", :ebook, write_bytes(File.join(root, "fx-pdf-early.pdf"), "x".b * 1020 + "%PDF-1.4\n".b + "y".b * 200, stamp + 3))
        fixed_book("fx-pdf-empty", "FX Pdf Empty", :ebook, write_bytes(File.join(root, "fx-pdf-empty.pdf"), "", stamp + 4))
        fixed_book("fx-pdf-comic", "FX Pdf Comic Record", :comicbook, write_bytes(File.join(root, "fx-pdf-comic.pdf"), pdf_bytes.call(72, 9000), stamp + 5), author: "C. Record")
        fixed_book("fx-pdf-graphic", "FX Pdf Graphic Ebook", :ebook, write_bytes(File.join(root, "fx-pdf-graphic.PDF"), pdf_bytes.call(73, 5000), stamp + 6), content_kind: :graphic)
        fixed_book("fx-comic", "FX Comic Natural", :comicbook, write_bytes(File.join(root, "fx-comic.cbz"), FixedLayoutMedia.natural_pages, stamp + 7), author: "N. Order")
        fixed_book("fx-comic-ebook", "FX Comic As Ebook", :ebook, write_bytes(File.join(root, "fx-comic-ebook.cbz"), FixedLayoutMedia.simple_pages(5), stamp + 8), content_kind: :graphic)
        fixed_book("fx-comic-stored", "FX Comic Stored", :comicbook, write_bytes(File.join(root, "fx-comic-stored.cbz"), FixedLayoutMedia.simple_pages(40, method: 0), stamp + 9))
        fixed_book("fx-comic-big", "FX Comic Ten Thousand", :comicbook, write_bytes(File.join(root, "fx-comic-big.cbz"), FixedLayoutMedia.many_pages(10_000), stamp + 10))
        series = File.join(root, "fx-series")
        { "Vol 10.cbz" => 3, "vol 2.cbz" => 4, "Vol 1.cbz" => 5 }.each_with_index { |(name, count), index| write_bytes(File.join(series, name), FixedLayoutMedia.simple_pages(count), stamp + 11 + index) }
        write_bytes(File.join(series, "extras", "Companion.pdf"), pdf_bytes.call(74, 2000), stamp + 20)
        write_bytes(File.join(series, "cover.jpg"), "cover", stamp)
        write_bytes(File.join(series, ".hidden.cbz"), FixedLayoutMedia.simple_pages(1), stamp)
        fixed_book("fx-series", "FX Series Directory", :comicbook, series)
        mixed = File.join(root, "fx-mixed")
        write_epub(File.join(mixed, "A Mixed.epub"), "fx-mixed", stamp)
        write_bytes(File.join(mixed, "B Mixed.pdf"), pdf_bytes.call(75, 1500), stamp)
        write_bytes(File.join(mixed, "C Mixed.cbz"), FixedLayoutMedia.simple_pages(2), stamp)
        fixed_book("fx-mixed", "FX Mixed Ebook", :ebook, mixed)
        broken = File.join(root, "fx-broken")
        FixedLayoutMedia.refused.each { |name, bytes| write_bytes(File.join(broken, "#{name}.cbz"), bytes, stamp) }
        write_bytes(File.join(broken, "bad-header.pdf"), "not a pdf", stamp)
        fixed_book("fx-broken", "FX Broken Archives", :comicbook, broken)
        fixed_book("fx-missing-comic", "FX Missing Comic", :comicbook, File.join(root, "fx-missing.cbz"))
        fixed_book("fx-edit-pdf", "FX Edit Pdf", :ebook, write_bytes(File.join(root, "fx-edit-pdf.pdf"), pdf_bytes.call(76, 6000), stamp + 21))
        fixed_book("fx-edit-pdf-comic", "FX Edit Pdf Comic", :comicbook, write_bytes(File.join(root, "fx-edit-pdf-comic.pdf"), pdf_bytes.call(77, 6000), stamp + 22))
        fixed_book("fx-edit-comic", "FX Edit Comic", :comicbook, write_bytes(File.join(root, "fx-edit-comic.cbz"), FixedLayoutMedia.natural_pages, stamp + 23))
        fixed_book("fx-edit-small", "FX Edit Small", :ebook, write_bytes(File.join(root, "fx-edit-small.cbz"), FixedLayoutMedia.simple_pages(5), stamp + 24), content_kind: :graphic)
        fixed_book("fx-edit-stored", "FX Edit Stored", :comicbook, write_bytes(File.join(root, "fx-edit-stored.cbz"), FixedLayoutMedia.simple_pages(40, method: 0), stamp + 25))
        fixed_book("fx-edit-big", "FX Edit Big", :comicbook, write_bytes(File.join(root, "fx-edit-big.cbz"), FixedLayoutMedia.many_pages(10_000), stamp + 26))
      end

      def fixed_book(key, title, type, path, **extra)
        @books[key] = create_book(title, type, path, **extra)
      end

      def fixed_assets(key, formats: Consumer::ReaderFormats::SUPPORTED)
        listed_assets(@books.fetch(key), formats: formats)
      end

      def fixed_asset(key, format)
        fixed_assets(key).find { |candidate| candidate.format == format } || raise("#{key} has no #{format}")
      end

      def reading_order_of(key, asset = fixed_asset(key, "cbz"))
        Consumer::LibraryAssets.new(@books.fetch(key), formats: %w[cbz]).reading_order(asset.id).last
      end

      def seed_fixed_layout_progress
        alice, bob = users.fetch("alice"), users.fetch("bob")
        stamp = Time.utc(2026, 11, 11, 9, 30, 0, 250_000)
        pdf = fixed_asset("fx-pdf", "pdf")
        pages = reading_order_of("fx-comic")
        stored = reading_order_of("fx-comic-stored")
        rows = [
          [ alice, "fx-pdf", pdf.id, { "href" => "document.pdf", "type" => "application/pdf", "locations" => { "position" => 7, "progression" => 0.5, "totalProgression" => 0.35, "fragments" => [ "page=7" ] } }, 4, stamp ],
          [ alice, "fx-comic", fixed_asset("fx-comic", "cbz").id, { "href" => pages[2][:href], "type" => pages[2][:media_type], "locations" => { "position" => 3, "totalProgression" => 0.08 } }, 2, stamp + 60 ],
          [ bob, "fx-comic", fixed_asset("fx-comic", "cbz").id, { "href" => pages[0][:href], "type" => pages[0][:media_type], "locations" => { "position" => 1 } }, 1, stamp + 120 ],
          [ alice, "fx-comic-stored", "stale-#{fixed_asset('fx-comic-stored', 'cbz').id}", { "href" => stored[1][:href], "type" => stored[1][:media_type], "locations" => { "position" => 2 } }, 3, stamp + 180 ],
          [ alice, "fx-pdf-comic", fixed_asset("fx-pdf-comic", "pdf").id, { "href" => "document.pdf", "type" => "application/pdf", "locations" => { "position" => 1.0 } }, 5, stamp + 240 ],
          [ alice, "fx-comic-ebook", fixed_asset("fx-comic-ebook", "cbz").id, { "href" => "x.png", "type" => "image/png", "locations" => { "totalProgression" => 1.4 } }, 6, nil ],
          [ bob, "fx-pdf", pdf.id, { "href" => "document.pdf", "type" => "application/pdf", "locations" => { "position" => 12 } }, 2, stamp + 300 ]
        ]
        rows.each_with_index do |(user, key, asset_id, locator, version, observed), index|
          ConsumerProgress.create!(user: user, book: @books.fetch(key), asset_id: asset_id, locator: locator, version: version, client_mutation_id: "fixed-#{index}", observed_at: observed, created_at: stamp, updated_at: stamp + (index * 20))
        end
        ConsumerReadingState.create!(user: alice, book: @books.fetch("fx-series"), status: :in_progress, created_at: stamp, updated_at: stamp + 400)
        ConsumerReadingState.create!(user: alice, book: @books.fetch("fx-pdf-late"), status: :finished, created_at: stamp, updated_at: stamp + 410)
      end

      def fixed_layout_catalogue_scenarios
        FORMAT_SELECTIONS.each_with_index do |value, index|
          headers = { Cases::FORMATS_HEADER => value }
          label = "fx-formats-#{index}"
          request("#{label}-library", "#{Cases::PREFIX}/library?limit=50", bearer: "alice-full", headers: headers)
          request("#{label}-library-head", "#{Cases::PREFIX}/library?limit=5", bearer: "alice-full", headers: headers, method: "HEAD")
          request("#{label}-library-ebook", "#{Cases::PREFIX}/library?type=ebook&limit=50", bearer: "bob-full", headers: headers)
          request("#{label}-library-audiobook", "#{Cases::PREFIX}/library?type=audiobook&limit=50", bearer: "alice-full", headers: headers)
          request("#{label}-library-title-query", "#{Cases::PREFIX}/library?q=fx&sort=title&limit=50", bearer: "alice-full", headers: headers)
          %w[unread in_progress finished].each { |status| request("#{label}-library-#{status}", "#{Cases::PREFIX}/library?status=#{status}&limit=50", bearer: "alice-full", headers: headers) }
          request("#{label}-continue", "#{Cases::PREFIX}/continue?limit=20", bearer: "alice-full", headers: headers)
          request("#{label}-continue-bob", "#{Cases::PREFIX}/continue", bearer: "bob-full", headers: headers)
        end
        %w[epub,pdf,cbz pdf epub].each_with_index do |value, index|
          chain("fx-page-recent-#{index}", "limit=4", value)
          chain("fx-page-title-#{index}", "limit=5&sort=title", value)
          chain("fx-page-query-#{index}", "limit=3&q=fx&sort=title", value)
        end
        INVALID_SELECTIONS.each { |name, value| request("fx-formats-invalid-#{name}", "#{Cases::PREFIX}/library", bearer: "alice-full", headers: { Cases::FORMATS_HEADER => value }) }
        request("fx-formats-invalid-continue", "#{Cases::PREFIX}/continue", bearer: "alice-full", headers: { Cases::FORMATS_HEADER => "pdf,mobi" })
        request("fx-formats-invalid-publication", "#{Cases::PREFIX}/library/#{@books.fetch('fx-pdf').id}", bearer: "alice-full", headers: { Cases::FORMATS_HEADER => "" })
        request("fx-formats-unknown-wins-over-missing-book", "#{Cases::PREFIX}/library/999999", bearer: "alice-full", headers: { Cases::FORMATS_HEADER => "mobi" })
        fixed_layout_cursor_scenarios
        fixed_layout_publication_scenarios
      end

      def chain(name, query, selection)
        cursor = nil
        12.times do |page|
          entry = request("#{name}-#{page + 1}", "#{Cases::PREFIX}/library?#{query}#{cursor ? "&cursor=#{CGI.escape(cursor)}" : ''}", bearer: "alice-full", headers: { Cases::FORMATS_HEADER => selection })
          cursor = entry.dig("json", "next_cursor")
          break unless cursor
        end
      end

      def fixed_layout_cursor_scenarios
        first = lambda do |selection|
          headers = selection ? { Cases::FORMATS_HEADER => selection } : {}
          request("fx-cursor-source-#{selection || 'absent'}", "#{Cases::PREFIX}/library?limit=3", bearer: "alice-full", headers: headers).dig("json", "next_cursor")
        end
        graphic = first.call("epub,pdf")
        legacy = first.call(nil)
        explicit = first.call("epub")
        replays = { "reordered" => [ graphic, "pdf,epub" ], "padded" => [ graphic, " epub , pdf " ], "duplicated" => [ graphic, "pdf,epub,pdf" ], "other-selection" => [ graphic, "epub" ], "wider-selection" => [ graphic, "epub,pdf,cbz" ],
                    "absent" => [ graphic, nil ], "legacy-on-graphic" => [ legacy, "epub,pdf" ], "legacy-on-epub-explicit" => [ legacy, "epub" ], "legacy-on-absent" => [ legacy, nil ], "explicit-epub-on-absent" => [ explicit, nil ] }
        replays.each do |name, (cursor, selection)|
          headers = selection ? { Cases::FORMATS_HEADER => selection } : {}
          request("fx-cursor-#{name}", "#{Cases::PREFIX}/library?limit=3&cursor=#{CGI.escape(cursor.to_s)}", bearer: "alice-full", headers: headers)
        end
        request("fx-cursor-other-account", "#{Cases::PREFIX}/library?limit=3&cursor=#{CGI.escape(graphic)}", bearer: "bob-full", headers: { Cases::FORMATS_HEADER => "epub,pdf" })
        title = request("fx-cursor-title-source", "#{Cases::PREFIX}/library?limit=4&sort=title", bearer: "alice-full", headers: { Cases::FORMATS_HEADER => "cbz" }).dig("json", "next_cursor")
        request("fx-cursor-title-replay", "#{Cases::PREFIX}/library?limit=4&sort=title&cursor=#{CGI.escape(title)}", bearer: "alice-full", headers: { Cases::FORMATS_HEADER => "cbz" })
        request("fx-cursor-title-wrong-selection", "#{Cases::PREFIX}/library?limit=4&sort=title&cursor=#{CGI.escape(title)}", bearer: "alice-full", headers: { Cases::FORMATS_HEADER => "pdf" })
      end

      def fixed_layout_publication_scenarios
        selections = { "absent" => nil, "epub" => "epub", "pdf" => "pdf", "cbz" => "cbz", "all" => "epub,pdf,cbz", "unsorted" => "pdf,epub" }
        (FIXED_KEYS + %w[fx-broken fx-missing-comic fx-pdf-early fx-pdf-empty comic-epub]).each do |key|
          book = @books.fetch(key)
          selections.each do |name, value|
            headers = value ? { Cases::FORMATS_HEADER => value } : {}
            request("fx-publication-#{key}-#{name}", "#{Cases::PREFIX}/library/#{book.id}", bearer: "alice-full", headers: headers)
          end
          request("fx-publication-#{key}-head", "#{Cases::PREFIX}/library/#{book.id}", bearer: "bob-full", method: "HEAD", headers: { Cases::FORMATS_HEADER => "epub,pdf,cbz" })
          request("fx-publication-#{key}-read-along-header", "#{Cases::PREFIX}/library/#{book.id}", bearer: "alice-full", headers: { Cases::FORMATS_HEADER => "cbz", Cases::FEATURES_HEADER => "unknown-feature" })
        end
      end

      def fixed_layout_asset_scenarios
        (FIXED_KEYS + %w[comic-epub]).each do |key|
          fixed_assets(key).each_with_index do |asset, index|
            path = asset_path(@books.fetch(key), asset.id)
            request("fx-asset-#{key}-#{index}-get", path, bearer: "alice-full")
            request("fx-asset-#{key}-#{index}-head", path, bearer: "bob-full", method: "HEAD")
            request("fx-asset-#{key}-#{index}-range", path, bearer: "alice-full", headers: { "Range" => "bytes=0-99" })
          end
        end
        detailed_fixed_asset("pdf", "fx-pdf", "pdf")
        detailed_fixed_asset("cbz", "fx-comic-stored", "cbz")
        detailed_fixed_asset("comic-pdf", "fx-pdf-comic", "pdf")
        fixed_layout_asset_failures
        fixed_layout_reading_order_scenarios
        fixed_layout_broken_scenarios
      end

      def detailed_fixed_asset(name, key, format)
        book = @books.fetch(key)
        asset = fixed_asset(key, format)
        path = asset_path(book, asset.id)
        size = asset.size_bytes
        { "first-byte" => "bytes=0-0", "prefix" => "bytes=0-1023", "middle" => "bytes=1000-5000", "open-ended" => "bytes=#{size - 100}-", "suffix" => "bytes=-100", "suffix-whole" => "bytes=-#{size + 50}",
          "past-end" => "bytes=#{size - 10}-#{size + 1000}", "last-byte" => "bytes=#{size - 1}-#{size - 1}", "start-at-size" => "bytes=#{size}-", "reversed" => "bytes=9-3", "multiple" => "bytes=0-1,5-6",
          "wrong-unit" => "items=0-1", "huge" => "bytes=99999999999999999999-" }.each { |label, value| request("fx-#{name}-range-#{label}", path, bearer: "alice-full", headers: { "Range" => value }) }
        etag = %("#{asset.id}")
        { "match" => etag, "weak" => "W/#{etag}", "star" => "*", "other" => '"zzz"', "list" => %("zzz", #{etag}) }.each { |label, value| request("fx-#{name}-if-none-match-#{label}", path, bearer: "alice-full", headers: { "If-None-Match" => value }) }
        request("fx-#{name}-if-none-match-head", path, bearer: "alice-full", method: "HEAD", headers: { "If-None-Match" => etag })
        request("fx-#{name}-if-range-match", path, bearer: "alice-full", headers: { "Range" => "bytes=0-9", "If-Range" => etag })
        request("fx-#{name}-if-range-other", path, bearer: "alice-full", headers: { "Range" => "bytes=0-9", "If-Range" => '"zzz"' })
        request("fx-#{name}-head-range", path, bearer: "alice-full", method: "HEAD", headers: { "Range" => "bytes=0-9" })
        request("fx-#{name}-other-user", path, bearer: "bob-full")
        request("fx-#{name}-wrong-scope", path, bearer: "alice-progress-only")
        request("fx-#{name}-unauthenticated", path)
        request("fx-#{name}-revoked", path, bearer: "alice-revoked")
        request("fx-#{name}-header-formats-ignored", path, bearer: "alice-full", headers: { Cases::FORMATS_HEADER => "epub" })
        request("fx-#{name}-invalid-formats-ignored", path, bearer: "alice-full", headers: { Cases::FORMATS_HEADER => "mobi" })
      end

      def fixed_layout_asset_failures
        pdf, cbz = @books.fetch("fx-pdf"), @books.fetch("fx-comic")
        pdf_asset, cbz_asset = fixed_asset("fx-pdf", "pdf"), fixed_asset("fx-comic", "cbz")
        request("fx-asset-pdf-id-on-comic", asset_path(cbz, pdf_asset.id), bearer: "alice-full")
        request("fx-asset-cbz-id-on-pdf", asset_path(pdf, cbz_asset.id), bearer: "alice-full")
        request("fx-asset-unknown", asset_path(pdf, "0" * 64), bearer: "alice-full")
        request("fx-asset-uppercase", asset_path(pdf, pdf_asset.id.upcase), bearer: "alice-full")
        request("fx-asset-missing-comic", asset_path(@books.fetch("fx-missing-comic"), "a" * 64), bearer: "alice-full")
        request("fx-asset-pdf-header-too-late", asset_path(@books.fetch("fx-pdf-early"), "b" * 64), bearer: "alice-full")
        request("fx-asset-with-suffix", "#{asset_path(pdf, pdf_asset.id)}.pdf", bearer: "alice-full", go: { "status" => 404, "code" => "not_found" })
        { "pdf-early" => "fx-pdf-early", "pdf-empty" => "fx-pdf-empty" }.each do |label, key|
          book = @books.fetch(key)
          request("fx-asset-#{label}-by-identity", asset_path(book, identity_of(book, book.file_path)), bearer: "alice-full")
        end
      end

      def identity_of(book, path)
        real = File.realpath(path)
        Consumer::LibraryAssets.new(book, formats: Consumer::ReaderFormats::SUPPORTED).send(:identity, File.stat(real), real)
      end

      def reading_order_path(book, asset_id)
        "#{asset_path(book, asset_id)}/reading_order"
      end

      def fixed_layout_reading_order_scenarios
        %w[fx-comic fx-comic-ebook fx-comic-stored fx-comic-big fx-series fx-mixed].each do |key|
          book = @books.fetch(key)
          fixed_assets(key).select { |candidate| candidate.format == "cbz" }.each_with_index do |asset, index|
            path = reading_order_path(book, asset.id)
            request("fx-reading-order-#{key}-#{index}", path, bearer: "alice-full")
            request("fx-reading-order-#{key}-#{index}-head", path, bearer: "bob-full", method: "HEAD")
          end
        end
        book, asset = @books.fetch("fx-comic"), fixed_asset("fx-comic", "cbz")
        path = reading_order_path(book, asset.id)
        request("fx-reading-order-wrong-scope", path, bearer: "alice-progress-only")
        request("fx-reading-order-unauthenticated", path)
        request("fx-reading-order-revoked", path, bearer: "alice-revoked")
        request("fx-reading-order-formats-header-ignored", path, bearer: "alice-full", headers: { Cases::FORMATS_HEADER => "epub" })
        request("fx-reading-order-invalid-formats-header-ignored", path, bearer: "alice-full", headers: { Cases::FORMATS_HEADER => "mobi" })
        request("fx-reading-order-unknown-asset", reading_order_path(book, "0" * 64), bearer: "alice-full")
        request("fx-reading-order-uppercase-asset", reading_order_path(book, asset.id.upcase), bearer: "alice-full")
        request("fx-reading-order-short-asset", reading_order_path(book, asset.id[0, 63]), bearer: "alice-full")
        request("fx-reading-order-unknown-book", reading_order_path(Book.new(id: 999_999), asset.id), bearer: "alice-full")
        request("fx-reading-order-bad-book", "#{Cases::PREFIX}/library/abc/assets/#{asset.id}/reading_order", bearer: "alice-full")
        request("fx-reading-order-of-another-book", reading_order_path(@books.fetch("fx-comic-stored"), asset.id), bearer: "alice-full")
        request("fx-reading-order-pdf-asset", reading_order_path(@books.fetch("fx-pdf"), fixed_asset("fx-pdf", "pdf").id), bearer: "alice-full")
        request("fx-reading-order-epub-asset", reading_order_path(@books.fetch("fx-mixed"), fixed_asset("fx-mixed", "epub").id), bearer: "alice-full")
        request("fx-reading-order-comic-epub-asset", reading_order_path(@books.fetch("comic-epub"), fixed_assets("comic-epub").first.id), bearer: "alice-full")
        request("fx-reading-order-audio-asset", reading_order_path(@books.fetch("big-audio"), listed_assets(@books.fetch("big-audio")).first.id), bearer: "alice-full")
        request("fx-reading-order-with-suffix", "#{path}.json", bearer: "alice-full", go: { "status" => 404, "code" => "not_found" })
        request("fx-reading-order-post", path, bearer: "alice-full", method: "POST", headers: { "Content-Type" => "application/json" }, body: "{}", go: ProgressCases::UNSUPPORTED_VERB)
      end

      def fixed_layout_broken_scenarios
        book = @books.fetch("fx-broken")
        Dir.children(book.file_path).sort.each do |name|
          path = File.join(book.file_path, name)
          id = identity_of(book, path)
          request("fx-broken-asset-#{name}", asset_path(book, id), bearer: "alice-full")
          request("fx-broken-reading-order-#{name}", reading_order_path(book, id), bearer: "alice-full") if name.end_with?(".cbz")
        end
      end

      def fixed_layout_projection_scenarios
        %w[alice-full bob-full].each do |label|
          FIXED_KEYS.each { |key| request("fx-projection-#{label}-#{key}", "#{Cases::PREFIX}/library/#{@books.fetch(key).id}", bearer: label, headers: { Cases::FORMATS_HEADER => "epub,pdf,cbz" }, at: tick) }
          %w[unread in_progress finished].each { |status| request("fx-projection-#{label}-library-#{status}", "#{Cases::PREFIX}/library?status=#{status}&limit=50", bearer: label, headers: { Cases::FORMATS_HEADER => "cbz,epub,pdf" }, at: tick) }
          request("fx-projection-#{label}-continue", "#{Cases::PREFIX}/continue?limit=20", bearer: label, headers: { Cases::FORMATS_HEADER => "cbz,epub,pdf" }, at: tick)
        end
      end

      def page_locator(key, position, **overrides)
        pages = reading_order_of(key)
        page = pages[position - 1] || { href: "missing.png", media_type: "image/png" }
        { "href" => page[:href], "type" => page[:media_type], "locations" => { "position" => position } }.merge(overrides.transform_keys(&:to_s))
      end

      def fixed_fields(key, locator, format, version: 0, mutation_id: nil, **extra)
        { "asset_id" => fixed_asset(key, format).id, "expected_version" => version, "client_mutation_id" => mutation_id || mutation, "locator" => locator }.merge(extra.transform_keys(&:to_s))
      end

      def fixed_layout_progress_scenarios
        seeded_row_scenarios
        pdf_page_scenarios
        pdf_shape_scenarios
        comic_page_scenarios
        comic_shape_scenarios
        fixed_layout_status_scenarios
        fixed_layout_read_back_scenarios
      end

      def pdf_page_scenarios
        key = "fx-pdf-late"
        first = fixed_fields(key, { "href" => "document.pdf", "type" => "application/pdf", "title" => "Chapter", "text" => { "highlight" => "x" }, "locations" => { "position" => 3, "progression" => 0.25, "totalProgression" => 0.1, "fragments" => [ "page=3" ] } }, "pdf",
          mutation_id: "55555555-5555-4555-8555-555555555555", observed_at: iso(-4000))
        put_progress("fx-pdf-create", key, first)
        put_progress("fx-pdf-retry", key, first, at: tick(30))
        put_progress("fx-pdf-retry-reordered", key, first.merge("locator" => first["locator"].to_a.reverse.to_h))
        put_progress("fx-pdf-retry-other-page", key, first.merge("locator" => PDF_LOCATOR.merge("locations" => { "position" => 4 })))
        get_progress("fx-pdf-read-back", key)
        put_progress("fx-pdf-update-no-fragment", key, fixed_fields(key, PDF_LOCATOR.merge("locations" => { "position" => 9 }), "pdf", version: 1, observed_at: iso(-3000)))
        put_progress("fx-pdf-update-last-page", key, fixed_fields(key, PDF_LOCATOR.merge("locations" => { "position" => 100_000, "fragments" => [ "page=100000" ] }), "pdf", version: 2, observed_at: iso(-2000)))
        put_progress("fx-pdf-older-activity", key, fixed_fields(key, PDF_LOCATOR, "pdf", version: 3, observed_at: iso(-9000)))
        put_progress("fx-pdf-resolve-older", key, fixed_fields(key, PDF_LOCATOR.merge("locations" => { "position" => 2 }), "pdf", version: 3, observed_at: iso(-9000), resolve_conflict: true))
        put_progress("fx-pdf-stale-version", key, fixed_fields(key, PDF_LOCATOR, "pdf", version: 1))
        put_progress("fx-pdf-other-account", key, fixed_fields(key, PDF_LOCATOR.merge("locations" => { "position" => 41 }), "pdf"), bearer: "bob-full")
        put_progress("fx-pdf-comic-record", "fx-edit-pdf-comic", fixed_fields("fx-edit-pdf-comic", PDF_LOCATOR, "pdf"))
        put_progress("fx-pdf-comic-record-retry-conflict", "fx-edit-pdf-comic", fixed_fields("fx-edit-pdf-comic", PDF_LOCATOR, "pdf"))
        put_progress("fx-pdf-graphic-ebook", "fx-pdf-graphic", fixed_fields("fx-pdf-graphic", PDF_LOCATOR.merge("locations" => { "position" => 12 }), "pdf"))
        put_progress("fx-mixed-pdf-asset", "fx-mixed", fixed_fields("fx-mixed", PDF_LOCATOR, "pdf"))
        put_progress("fx-mixed-epub-asset-with-epub-locator", "fx-mixed", fixed_fields("fx-mixed", ProgressCases::LOCATOR, "epub", version: 1))
        put_progress("fx-mixed-cbz-asset-with-pdf-locator", "fx-mixed", fixed_fields("fx-mixed", PDF_LOCATOR, "cbz", version: 2))
        put_progress("fx-mixed-epub-asset-with-pdf-locator", "fx-mixed", fixed_fields("fx-mixed", PDF_LOCATOR, "epub", version: 2))
        early = @books.fetch("fx-pdf-early")
        put_progress("fx-pdf-header-too-late-asset", "fx-pdf-early", { "asset_id" => identity_of(early, early.file_path), "expected_version" => 0, "client_mutation_id" => mutation, "locator" => PDF_LOCATOR })
        put_progress("fx-pdf-asset-of-another-book", "fx-pdf-late", fixed_fields("fx-pdf-late", PDF_LOCATOR, "pdf", version: 4).merge("asset_id" => fixed_asset("fx-pdf", "pdf").id))
        put_progress("fx-pdf-missing-media", "fx-missing-comic", { "asset_id" => "c" * 64, "expected_version" => 0, "client_mutation_id" => mutation, "locator" => PDF_LOCATOR })
      end

      def seeded_row_scenarios
        pdf = "fx-pdf"
        put_progress("fx-seeded-pdf-stale-version", pdf, fixed_fields(pdf, PDF_LOCATOR, "pdf", version: 3))
        put_progress("fx-seeded-pdf-update", pdf, fixed_fields(pdf, PDF_LOCATOR.merge("locations" => { "position" => 8, "fragments" => [ "page=8" ] }), "pdf", version: 4, observed_at: iso(-100)))
        put_progress("fx-seeded-pdf-older-than-seed", pdf, fixed_fields(pdf, PDF_LOCATOR, "pdf", version: 5, observed_at: "2020-01-01T00:00:00Z"))
        comic = "fx-comic"
        put_progress("fx-seeded-comic-update", comic, fixed_fields(comic, page_locator(comic, 6), "cbz", version: 2, observed_at: iso(-90)))
        put_progress("fx-seeded-comic-other-account", comic, fixed_fields(comic, page_locator(comic, 2), "cbz", version: 1), bearer: "bob-full")
        stored = "fx-comic-stored"
        put_progress("fx-seeded-stale-asset-replaced", stored, fixed_fields(stored, page_locator(stored, 4), "cbz", version: 3, observed_at: iso(-80)))
        put_progress("fx-seeded-pdf-comic-float-position", "fx-pdf-comic", fixed_fields("fx-pdf-comic", PDF_LOCATOR, "pdf", version: 5, observed_at: iso(-70)))
        put_progress("fx-seeded-ebook-comic-out-of-range-fraction", "fx-comic-ebook", fixed_fields("fx-comic-ebook", page_locator("fx-comic-ebook", 1), "cbz", version: 6, observed_at: iso(-60)))
      end

      def pdf_shape_scenarios
        key = "fx-edit-pdf"
        locations = ->(extra) { PDF_LOCATOR.merge("locations" => { "position" => 5 }.merge(extra)) }
        refused = {
          "position-zero" => PDF_LOCATOR.merge("locations" => { "position" => 0 }), "position-negative" => PDF_LOCATOR.merge("locations" => { "position" => -3 }),
          "position-over-limit" => PDF_LOCATOR.merge("locations" => { "position" => 100_001 }), "position-float" => PDF_LOCATOR.merge("locations" => { "position" => 3.0 }),
          "position-float-fraction" => PDF_LOCATOR.merge("locations" => { "position" => 3.5 }), "position-string" => PDF_LOCATOR.merge("locations" => { "position" => "3" }),
          "position-null" => PDF_LOCATOR.merge("locations" => { "position" => nil }), "position-missing" => PDF_LOCATOR.merge("locations" => {}),
          "position-huge" => PDF_LOCATOR.merge("locations" => { "position" => 10**30 }), "position-array" => PDF_LOCATOR.merge("locations" => { "position" => [ 3 ] }),
          "href-other" => PDF_LOCATOR.merge("href" => "doc.pdf"), "href-case" => PDF_LOCATOR.merge("href" => "Document.pdf"), "href-subdir" => PDF_LOCATOR.merge("href" => "a/document.pdf"),
          "type-other" => PDF_LOCATOR.merge("type" => "application/octet-stream"), "type-missing" => PDF_LOCATOR.except("type"), "type-null" => PDF_LOCATOR.merge("type" => nil),
          "type-case" => PDF_LOCATOR.merge("type" => "Application/PDF"), "type-number" => PDF_LOCATOR.merge("type" => 5),
          "fragment-wrong-page" => locations.call("fragments" => [ "page=6" ]), "fragment-empty" => locations.call("fragments" => []), "fragment-string" => locations.call("fragments" => "page=5"),
          "fragment-two" => locations.call("fragments" => [ "page=5", "page=5" ]), "fragment-number" => locations.call("fragments" => [ 5 ]), "fragment-padded" => locations.call("fragments" => [ "page=5 " ]),
          "fragment-leading-zero" => locations.call("fragments" => [ "page=05" ]), "fragment-object" => locations.call("fragments" => { "page" => 5 }),
          "locator-extra-key" => PDF_LOCATOR.merge("vendor" => 1), "locations-extra-key" => locations.call("cfi" => "/2/4"), "locations-read-along" => locations.call("readAlong" => { "generation" => "c" * 64, "audio" => 0, "offset_ms" => 0 }),
          "locator-text-string" => PDF_LOCATOR.merge("text" => "x"), "locator-text-array" => PDF_LOCATOR.merge("text" => [ 1 ]),
          "title-number" => PDF_LOCATOR.merge("title" => 4), "title-array" => PDF_LOCATOR.merge("title" => [ "x" ]), "title-too-long" => PDF_LOCATOR.merge("title" => "t" * 1025),
          "title-multibyte-too-long" => PDF_LOCATOR.merge("title" => "é" * 513), "progression-high" => locations.call("progression" => 1.5), "total-progression-negative" => locations.call("totalProgression" => -0.1),
          "locator-null" => nil, "locator-empty" => {}, "locations-array" => PDF_LOCATOR.merge("locations" => [ 5 ])
        }
        refused.each { |name, locator| put_progress("fx-pdf-invalid-#{name}", key, fixed_fields(key, locator, "pdf", mutation_id: "66666666-6666-4666-8666-666666666666")) }
        put_progress("fx-pdf-boundary-position-1", key, fixed_fields(key, PDF_LOCATOR.merge("locations" => { "position" => 1 }), "pdf", observed_at: iso(-2500)))
        put_progress("fx-pdf-boundary-title-1024", key, fixed_fields(key, PDF_LOCATOR.merge("title" => "t" * 1024, "locations" => { "position" => 2 }), "pdf", version: 1, observed_at: iso(-2400)))
        put_progress("fx-pdf-boundary-title-1024-multibyte", key, fixed_fields(key, PDF_LOCATOR.merge("title" => "é" * 512, "locations" => { "position" => 2 }), "pdf", version: 2, observed_at: iso(-2300)))
        put_progress("fx-pdf-title-null-text-object", key, fixed_fields(key, PDF_LOCATOR.merge("title" => nil, "text" => { "a" => [ 1 ] }, "locations" => { "position" => 7, "progression" => 1, "totalProgression" => 0 }), "pdf", version: 3, observed_at: iso(-2200)))
        put_progress("fx-pdf-integer-fractions-and-fragment", key, fixed_fields(key, locations.call("progression" => 0, "totalProgression" => 1, "fragments" => [ "page=5" ]), "pdf", version: 4, observed_at: iso(-2100)))
        put_progress("fx-pdf-exponent-position", key, JSON.generate(fixed_fields(key, PDF_LOCATOR, "pdf", version: 5)).sub('"position":3', '"position":3e0'))
        put_progress("fx-pdf-duplicate-key-last-wins", key, JSON.generate(fixed_fields(key, PDF_LOCATOR, "pdf", version: 5)).sub('"position":3', '"position":99,"position":4'))
        put_progress("fx-pdf-seconds-with-locator", key, fixed_fields(key, PDF_LOCATOR, "pdf", version: 5, position_seconds: 1))
        put_progress("fx-pdf-oversized-text", key, fixed_fields(key, PDF_LOCATOR.merge("text" => { "x" => "y" * 17_000 }), "pdf", version: 5))
        get_progress("fx-pdf-after-shape", key)
      end

      def comic_page_scenarios
        key = "fx-edit-comic"
        put_progress("fx-comic-page-1", key, fixed_fields(key, page_locator(key, 1), "cbz", mutation_id: "77777777-7777-4777-8777-777777777777", observed_at: iso(-3900)))
        put_progress("fx-comic-page-1-retry", key, fixed_fields(key, page_locator(key, 1), "cbz", mutation_id: "77777777-7777-4777-8777-777777777777", observed_at: iso(-3900)), at: tick(20))
        put_progress("fx-comic-page-2-with-optional-fields", key, fixed_fields(key, page_locator(key, 2, "title" => "Two", "text" => { "a" => 1 }, "locations" => { "position" => 2, "progression" => 0.2, "totalProgression" => 0.06 }), "cbz", version: 1, observed_at: iso(-3800)))
        pages = reading_order_of(key)
        put_progress("fx-comic-last-page", key, fixed_fields(key, page_locator(key, pages.size), "cbz", version: 2, observed_at: iso(-3700)))
        put_progress("fx-comic-older-activity", key, fixed_fields(key, page_locator(key, 3), "cbz", version: 3, observed_at: iso(-9500)))
        put_progress("fx-comic-resolve-older", key, fixed_fields(key, page_locator(key, 3), "cbz", version: 3, observed_at: iso(-9500), resolve_conflict: true))
        put_progress("fx-comic-other-account", key, fixed_fields(key, page_locator(key, 4), "cbz"), bearer: "bob-full")
        get_progress("fx-comic-read-back", key)
        (1..pages.size).step(5).each { |position| put_progress("fx-comic-sweep-#{position}", "fx-edit-stored", fixed_fields("fx-edit-stored", page_locator("fx-edit-stored", position), "cbz", version: position == 1 ? 0 : ((position - 1) / 5), observed_at: iso(-3000 + position))) if position <= 40 }
        big = "fx-edit-big"
        put_progress("fx-comic-big-first", big, fixed_fields(big, page_locator(big, 1), "cbz"))
        put_progress("fx-comic-big-last", big, fixed_fields(big, page_locator(big, 10_000), "cbz", version: 1, observed_at: iso(-1000)))
        put_progress("fx-comic-big-past-last", big, fixed_fields(big, page_locator(big, 10_001), "cbz", version: 2))
        series = "fx-series"
        series_assets = fixed_assets(series).select { |candidate| candidate.format == "cbz" }
        put_progress("fx-series-second-volume", series, fixed_fields(series, page_locator(series, 2, "type" => reading_order_of(series, series_assets[1])[1][:media_type]), "cbz").merge("asset_id" => series_assets[1].id))
        put_progress("fx-series-pdf-companion", series, fixed_fields(series, PDF_LOCATOR, "pdf", version: 1))
        put_progress("fx-comic-ebook-record", "fx-edit-small", fixed_fields("fx-edit-small", page_locator("fx-edit-small", 2), "cbz"))
        put_progress("fx-comic-epub-in-comic-record", "comic-epub", ebook_fields("comic-epub", ProgressCases::LOCATOR).merge("asset_id" => fixed_assets("comic-epub").first.id))
        put_progress("fx-comic-epub-in-comic-record-pdf-locator", "comic-epub", ebook_fields("comic-epub", PDF_LOCATOR, version: 1).merge("asset_id" => fixed_assets("comic-epub").first.id))
        put_progress("fx-comic-broken-asset", "fx-broken", { "asset_id" => identity_of(@books.fetch("fx-broken"), File.join(@books.fetch("fx-broken").file_path, "symlink.cbz")), "expected_version" => 0, "client_mutation_id" => mutation, "locator" => page_locator("fx-comic", 1) })
        put_progress("fx-comic-missing-media", "fx-missing-comic", { "asset_id" => "d" * 64, "expected_version" => 0, "client_mutation_id" => mutation, "locator" => page_locator("fx-comic", 1) })
      end

      def comic_shape_scenarios
        key = "fx-edit-small"
        pages = reading_order_of(key)
        refused = {
          "position-zero" => page_locator(key, 1).merge("locations" => { "position" => 0 }), "position-past-end" => page_locator(key, 6), "position-float" => page_locator(key, 1).merge("locations" => { "position" => 1.0 }),
          "position-string" => page_locator(key, 1).merge("locations" => { "position" => "1" }), "position-missing" => page_locator(key, 1).merge("locations" => {}), "position-over-limit" => page_locator(key, 1).merge("locations" => { "position" => 100_001 }),
          "href-of-other-page" => page_locator(key, 1).merge("href" => pages[1][:href]), "href-raw-name" => page_locator(key, 1).merge("href" => "p01.png "), "href-case" => page_locator(key, 1).merge("href" => "P01.png"),
          "href-encoded-equivalent" => page_locator(key, 1).merge("href" => "p%30%31.png"), "href-missing" => page_locator(key, 1).except("href"), "type-wrong-image" => page_locator(key, 1).merge("type" => "image/jpeg"),
          "type-missing" => page_locator(key, 1).except("type"), "type-null" => page_locator(key, 1).merge("type" => nil), "type-pdf" => page_locator(key, 1).merge("type" => "application/pdf"),
          "fragments-null" => page_locator(key, 1).merge("locations" => { "position" => 1, "fragments" => nil }), "fragments-array" => page_locator(key, 1).merge("locations" => { "position" => 1, "fragments" => [ "page=1" ] }),
          "pdf-locator" => PDF_LOCATOR, "epub-locator" => ProgressCases::LOCATOR, "locator-extra-key" => page_locator(key, 1).merge("vendor" => 1), "locations-extra-key" => page_locator(key, 1).merge("locations" => { "position" => 1, "cfi" => "/2" }),
          "locations-read-along" => page_locator(key, 1).merge("locations" => { "position" => 1, "readAlong" => { "generation" => "c" * 64, "audio" => 0, "offset_ms" => 0 } }), "title-too-long" => page_locator(key, 1).merge("title" => "t" * 1025),
          "text-string" => page_locator(key, 1).merge("text" => "x"), "href-dotdot" => page_locator(key, 1).merge("href" => "../p01.png"), "href-absolute" => page_locator(key, 1).merge("href" => "/p01.png")
        }
        refused.each { |name, locator| put_progress("fx-comic-invalid-#{name}", key, fixed_fields(key, locator, "cbz", mutation_id: "88888888-8888-4888-8888-888888888888")) }
        put_progress("fx-comic-valid-after-refusals", key, fixed_fields(key, page_locator(key, 5), "cbz", observed_at: iso(-500)))
        put_progress("fx-comic-position-exponent", key, JSON.generate(fixed_fields(key, page_locator(key, 2), "cbz", version: 1)).sub('"position":2', '"position":2e0'))
        put_progress("fx-comic-seconds-with-locator", key, fixed_fields(key, page_locator(key, 2), "cbz", version: 1, position_seconds: 3))
      end

      def fixed_layout_status_scenarios
        selections = [ nil, "pdf", "cbz", "epub,pdf,cbz", "mobi", "" ]
        %w[fx-pdf-comic fx-comic-stored fx-comic-ebook fx-mixed fx-pdf-graphic fx-series].each_with_index do |key, index|
          put_status("fx-status-#{key}", key, { "status" => %w[finished in_progress unread][index % 3] })
          selections.each_with_index do |selection, position|
            headers = selection ? { Cases::FORMATS_HEADER => selection } : {}
            put_status("fx-status-#{key}-formats-#{position}", key, { "status" => %w[in_progress finished][position % 2] }, extra_headers: headers)
          end
        end
        put_status("fx-status-invalid-comic", "fx-comic-stored", { "status" => "done" })
        put_status("fx-status-other-account-comic", "fx-comic-stored", { "status" => "finished" }, bearer: "bob-full")
        put_status("fx-status-missing-comic", "fx-missing-comic", { "status" => "finished" })
        put_status("fx-status-broken-directory", "fx-broken", { "status" => "in_progress" })
        put_status("fx-status-read-only", "fx-pdf", { "status" => "finished" }, bearer: "alice-read-only")
      end

      def fixed_layout_read_back_scenarios
        %w[fx-pdf fx-pdf-late fx-pdf-comic fx-comic fx-comic-stored fx-comic-ebook fx-comic-big fx-series fx-mixed fx-missing-comic].each do |key|
          get_progress("fx-read-#{key}", key)
          get_progress("fx-read-#{key}-bob", key, bearer: "bob-full")
          get_progress("fx-read-#{key}-head", key, method: "HEAD")
        end
        get_progress("fx-read-no-scope", "fx-pdf", bearer: "alice-progress-only")
        fixed_layout_projection_scenarios
      end
    end
  end
end
