# frozen_string_literal: true

require "test_helper"
require "timeout"

# Separate connections, so one request's retirement can hold the book lock
# while another request tries to store a replacement plan.
class LibraryReplacementAdmissionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @requests_before = Request.maximum(:id).to_i
    @books_before = Book.maximum(:id).to_i
  end

  teardown do
    Download.joins(:request).where("requests.id > ?", @requests_before).delete_all
    Request.where("id > ?", @requests_before).delete_all
    Book.where("id > ?", @books_before).delete_all
  end

  test "replacement admission waits while another request retires plans for the same book" do
    previous = "/audiobooks/Ada/Title"
    destination = "/audiobooks/Ada/Title (2)"
    book = Book.create!(title: "Title", author: "Ada", book_type: :audiobook, file_path: previous)
    retiring_request = Request.create!(book: book, user: users(:one), status: :failed)
    retiring_request.downloads.create!(
      name: "Earlier plan",
      status: :failed,
      library_replacement_state: JSON.generate(
        "previous_path" => previous,
        "destination" => destination,
        "book_path" => destination,
        "layout" => "directory",
        "cleanup_pending" => true
      )
    )
    admitting_request = Request.create!(book: book, user: users(:one), status: :downloading)
    admitting = admitting_request.downloads.create!(name: "New plan", status: :completed, progress: 100)

    inside = Queue.new
    gate = Queue.new
    finished = Queue.new
    waited = false
    retirement_error = nil
    admission_error = nil

    retirement = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        LibraryReplacement.stub(:cleanup_actionable?, lambda { |*|
          unless waited
            waited = true
            inside << true
            gate.pop
          end
          false
        }) do
          LibraryReplacement.release_conflicting_plans!(book, artifact_id: -1)
        end
      end
    rescue StandardError => error
      retirement_error = error
      inside << :error
    end

    Timeout.timeout(5) { flunk retirement_error.message if inside.pop == :error }
    admission = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        LibraryReplacement.persist!(
          admitting,
          previous_path: previous,
          destination: "#{destination}-new",
          book_path: "#{destination}-new",
          layout: "directory"
        )
        finished << true
      end
    rescue StandardError => error
      admission_error = error
      finished << :error
    end

    result = begin
      Timeout.timeout(1) { finished.pop }
    rescue Timeout::Error
      :blocked
    end
    gate << true
    retirement.join(5)
    admission.join(5)

    assert_nil retirement_error
    assert_nil admission_error
    assert_equal :blocked, result
    assert admitting.reload.library_replacement_state.present?
  end
end
