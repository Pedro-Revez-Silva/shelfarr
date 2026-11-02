# frozen_string_literal: true

require "json"
require "pathname"

# Remembers a confirmed replacement before bytes are published. A later attempt
# reuses that destination, and the previous file stays recorded until deletion
# succeeds.
class LibraryReplacement
  MAX_RELATIVE_FILES = 1000

  class UnreadablePlanError < StandardError; end

  Plan = Data.define(
    :previous_path,
    :destination,
    :book_path,
    :layout,
    :cleanup_pending,
    :raw
  ) do
    def file?
      layout == "file"
    end
  end

  class << self
    def load(download)
      raw = download.library_replacement_state
      return if raw.blank?

      data = JSON.parse(raw)
      return invalid_plan("replacement plan is not an object") unless data.is_a?(Hash)

      previous_path = data["previous_path"].to_s
      destination = data["destination"].to_s
      book_path = data["book_path"].to_s
      layout = data["layout"].to_s
      if previous_path.blank? || destination.blank? || book_path.blank? || !layout.in?(%w[file directory])
        return invalid_plan("replacement plan is incomplete")
      end

      Plan.new(
        previous_path: previous_path,
        destination: destination,
        book_path: book_path,
        layout: layout,
        cleanup_pending: data["cleanup_pending"] != false,
        raw: raw
      )
    rescue JSON::ParserError => error
      RemoteResult::Failed.new(error)
    end

    def persist!(download, previous_path:, destination:, book_path:, layout:)
      existing = load(download)
      return existing if existing.is_a?(Plan) || RemoteResult.failed?(existing)

      payload = {
        "previous_path" => previous_path.to_s,
        "destination" => destination.to_s,
        "book_path" => book_path.to_s,
        "layout" => layout.to_s,
        "cleanup_pending" => true
      }
      raw = JSON.generate(payload)
      updated = Download.where(id: download.id, library_replacement_state: [ nil, "" ]).update_all(
        library_replacement_state: raw,
        updated_at: Time.current
      )
      if updated == 1
        download.library_replacement_state = raw
        return plan_from(payload, raw)
      end

      download.reload
      load(download)
    end

    def adopt!(download, book, layout:)
      current = book.file_path.to_s
      return if current.blank?

      donors = Download.joins(:request)
        .where(requests: { book_id: book.id })
        .where.not(id: download.id)
        .where.not(library_replacement_state: [ nil, "" ])
        .order(updated_at: :desc, id: :desc)
      donors.each do |candidate|
        plan = load(candidate)
        return plan if RemoteResult.failed?(plan)
        next unless plan.is_a?(Plan) && plan.layout == layout

        matched = same_path?(plan.previous_path, current)
        return matched if RemoteResult.failed?(matched)
        next unless matched
        next if swap_committed?(book, plan)

        return persist!(
          download,
          previous_path: plan.previous_path,
          destination: plan.destination,
          book_path: plan.book_path,
          layout: plan.layout
        )
      end

      nil
    end

    def matches_book?(plan, book)
      current = book.file_path.to_s
      return false if current.blank?

      previous_match = same_path?(current, plan.previous_path)
      return previous_match if RemoteResult.failed?(previous_match)
      return true if previous_match

      same_path?(current, plan.book_path)
    end

    # True when the new file is attached and the previous file still has to be
    # removed. An unreadable record also blocks forgetting the download.
    def cleanup_actionable?(download, book = nil)
      plan = load(download)
      return true if RemoteResult.failed?(plan)
      return false unless plan.is_a?(Plan) && plan.cleanup_pending

      book ||= download.request&.book
      return true unless book

      swap_committed?(book, plan)
    end

    def cleanup_actionable_for_request?(request)
      request.downloads.where.not(library_replacement_state: [ nil, "" ]).any? do |download|
        cleanup_actionable?(download)
      end
    end

    def cleanup_actionable_for_book?(book)
      return false unless book&.persisted?

      Download.joins(:request)
        .where(requests: { book_id: book.id })
        .where.not(library_replacement_state: [ nil, "" ])
        .any? { |download| cleanup_actionable?(download, book) }
    end

    def finish_cleanup!(download)
      download.reload
      plan = load(download)
      return plan if RemoteResult.failed?(plan)
      return true unless plan.is_a?(Plan)

      book = download.request&.book
      return false unless book

      book.reload
      return true unless cleanup_actionable?(download, book)

      deleted = SafeLibraryDeletionService.delete_previous_library_file!(book, plan.previous_path)
      return deleted unless deleted == true

      clear!(download, plan.raw)
    end

    def finish_pending_cleanups!
      Download.where.not(library_replacement_state: [ nil, "" ]).find_each do |download|
        finish_cleanup!(download)
      rescue StandardError => error
        Rails.logger.warn(
          "[LibraryReplacement] Could not finish cleanup for download ##{download.id}: #{error.class}"
        )
      end
    end

    # Removes a partial publish that can be tied to this download, or reports
    # that the published files could not be established. A committed swap is
    # left for finish_cleanup! so the previous file is not dropped.
    def prepare_cancellation!(download)
      plan = load(download)
      return plan if RemoteResult.failed?(plan)

      book = download.request&.book
      return false unless book

      if plan.is_a?(Plan)
        return false if cleanup_actionable?(download, book)

        abandoned = abandon!(book, plan)
        return abandoned unless abandoned == true

        return clear!(download, plan.raw)
      end

      return true if book.file_path.present?

      clean_untracked_import!(download, book)
    end

    def same_path?(left, right)
      return false if left.blank? || right.blank?

      Pathname(left).expand_path == Pathname(right).expand_path
    rescue ArgumentError => error
      RemoteResult::Failed.new(error)
    end

    private

    def plan_from(payload, raw)
      Plan.new(
        previous_path: payload["previous_path"],
        destination: payload["destination"],
        book_path: payload["book_path"],
        layout: payload["layout"],
        cleanup_pending: true,
        raw: raw
      )
    end

    def invalid_plan(message)
      RemoteResult::Failed.new(JSON::ParserError.new(message))
    end

    def clear!(download, raw)
      updated = Download.where(id: download.id, library_replacement_state: raw).update_all(
        library_replacement_state: nil,
        updated_at: Time.current
      )
      if updated == 1
        download.library_replacement_state = nil
        return true
      end

      download.reload
      download.library_replacement_state.blank?
    end

    def swap_committed?(book, plan)
      current = book.file_path.to_s
      return false if current.blank?

      same = same_path?(current, plan.previous_path)
      return false if same == true || RemoteResult.failed?(same)

      !SafeLibraryDeletionService.overlapping_library_paths?(current, plan.previous_path)
    end

    def abandon!(book, plan)
      paths = [ plan.book_path, plan.destination ].compact.uniq.sort_by(&:length)
      decisions = paths.map { |path| removable_replacement_path?(book, plan, path) }
      failed = decisions.find { |decision| RemoteResult.failed?(decision) }
      return failed if failed
      return false if decisions.any?(false)

      paths.zip(decisions).each do |path, decision|
        next if decision == :absent

        deleted = delete_owned_path!(book, path)
        return deleted unless deleted == true
      end
      true
    end

    def removable_replacement_path?(book, plan, path)
      existed = path_exists?(path)
      return existed if RemoteResult.failed?(existed)
      return :absent unless existed

      same = same_path?(path, plan.previous_path)
      return same if RemoteResult.failed?(same)
      return false if same
      return false if SafeLibraryDeletionService.overlapping_library_paths?(path, plan.previous_path)
      return false if File.symlink?(path)

      root = output_root_for(book).to_s
      contained = inside_root?(path, root)
      return contained if RemoteResult.failed?(contained)
      return false unless contained

      root_match = same_path?(path, root)
      return root_match if RemoteResult.failed?(root_match)
      return false if root_match

      true
    end

    def clean_untracked_import!(download, book)
      return true if book.file_path.present?

      root = output_root_for(book).to_s
      return false if root.blank?

      destination = PathTemplateService.build_destination(book, base_path: root)
      return false if destination.blank?

      contained = inside_root?(destination, root)
      return contained if RemoteResult.failed?(contained)
      return false unless contained

      root_match = same_path?(destination, root)
      return root_match if RemoteResult.failed?(root_match)
      return false if root_match
      return false if File.symlink?(destination)

      existed = path_exists?(destination)
      return existed if RemoteResult.failed?(existed)
      return true unless existed
      return false unless File.directory?(destination)

      source = download.download_path.to_s
      return false if source.blank? || File.symlink?(source) || !File.directory?(source)
      return false if SafeLibraryDeletionService.overlapping_library_paths?(destination, source)

      destination_files = relative_library_files(destination)
      return destination_files if RemoteResult.failed?(destination_files)
      source_files = relative_library_files(source)
      return source_files if RemoteResult.failed?(source_files)
      return false unless destination_files.all? { |relative| source_files.include?(relative) }

      delete_owned_path!(book, destination)
    end

    def relative_library_files(root)
      root_path = Pathname(root).expand_path
      return RemoteResult::Failed.new(Errno::ELOOP.new("symlink")) if File.symlink?(root_path)
      return [] unless File.directory?(root_path)

      files = []
      pending = [ root_path ]
      visited = 0
      while (current = pending.pop)
        Dir.each_child(current.to_s) do |name|
          visited += 1
          if visited > MAX_RELATIVE_FILES
            return RemoteResult::Failed.new(ArgumentError.new("library walk is too large"))
          end

          path = current.join(name)
          if File.symlink?(path)
            return RemoteResult::Failed.new(Errno::ELOOP.new("symlink"))
          elsif File.directory?(path)
            pending << path
          elsif File.file?(path)
            files << path.relative_path_from(root_path).to_s
          else
            return RemoteResult::Failed.new(ArgumentError.new("unsupported library entry"))
          end
        end
      end
      files
    rescue SystemCallError => error
      RemoteResult::Failed.new(error)
    end

    def delete_owned_path!(book, path)
      record = book.class.find_by(id: book.id)
      return false unless record

      record.file_path = path
      SafeLibraryDeletionService.new(record).delete!
      true
    rescue SafeLibraryDeletionService::Error => error
      RemoteResult::Failed.new(error)
    end

    def path_exists?(path)
      return false if path.blank?

      File.exist?(path) || File.symlink?(path)
    rescue SystemCallError => error
      RemoteResult::Failed.new(error)
    end

    def inside_root?(path, root)
      return false if path.blank? || root.blank?

      relative = Pathname(path).expand_path.relative_path_from(Pathname(root).expand_path)
      relative.to_s != ".." && !relative.to_s.start_with?("..#{File::SEPARATOR}")
    rescue ArgumentError => error
      RemoteResult::Failed.new(error)
    end

    def output_root_for(book)
      if book.comicbook?
        SettingsService.get(:comicbook_output_path)
      elsif book.ebook?
        SettingsService.get(:ebook_output_path)
      else
        SettingsService.get(:audiobook_output_path)
      end
    end
  end
end
