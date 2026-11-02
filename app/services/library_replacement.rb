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
    :published_paths,
    :publications_recorded,
    :raw
  ) do
    def file?
      layout == "file"
    end
  end

  # Files this import has actually copied into the library. Unlike a Plan,
  # there is no previous copy to preserve.
  Publication = Data.define(:published_paths, :raw)

  class << self
    def load(download)
      raw = download.library_replacement_state
      return if raw.blank?

      data = JSON.parse(raw)
      return invalid_plan("replacement plan is not an object") unless data.is_a?(Hash)

      published_paths = published_paths_from(data)
      return published_paths if RemoteResult.failed?(published_paths)

      if publication_journal?(data)
        return Publication.new(published_paths: published_paths, raw: raw)
      end

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
        published_paths: published_paths,
        publications_recorded: data.key?("published_paths"),
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
        next unless same_replacement_artifact?(candidate, download.search_result_id)

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

    # A different release must not keep writing into the previous release's
    # destination. Clear that plan before the new artifact chooses a path.
    def release_conflicting_plans!(book, artifact_id:, except_download_id: nil)
      return false unless book&.persisted?

      scope = Download.joins(:request)
        .where(requests: { book_id: book.id })
        .where.not(library_replacement_state: [ nil, "" ])
      scope = scope.where.not(id: except_download_id) if except_download_id
      scope.find_each do |candidate|
        next if same_replacement_artifact?(candidate, artifact_id)

        plan = load(candidate)
        return plan if RemoteResult.failed?(plan)
        next unless plan.is_a?(Plan)
        next if cleanup_actionable?(candidate, book)

        prepared = prepare_cancellation!(candidate)
        return prepared unless prepared == true
      end
      true
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

      # The Book row can name the new path before that path is durable. Keep
      # the previous copy until the attached file or directory is actually there.
      present = attached_library_artifact?(book.file_path)
      return present if RemoteResult.failed?(present)
      return false unless present

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

      return clear!(download, plan.raw) if plan.is_a?(Publication) && publication_retained?(download, book)

      return true unless plan.is_a?(Publication)

      removable = published_paths_not_referenced_by(book, plan.published_paths)
      return removable if RemoteResult.failed?(removable)

      removed = remove_published_files!(book, removable, protected_path: nil)
      return removed unless removed == true

      clear!(download, plan.raw)
    end

    # Records the destination before publication so a later sync error cannot
    # hide a file that already landed. Cancellation deletes this list and does
    # not guess from templates or filenames.
    def record_published_path!(download, path)
      normalized = Pathname(path.to_s).expand_path.to_s
      return invalid_plan("published path is blank") if normalized.blank?

      5.times do
        download.reload
        raw = download.library_replacement_state.to_s
        data = raw.blank? ? {} : JSON.parse(raw)
        return invalid_plan("replacement plan is not an object") unless data.is_a?(Hash)

        paths = published_paths_from(data)
        return paths if RemoteResult.failed?(paths)
        if paths.include?(normalized)
          download.library_replacement_state = raw.presence
          return true
        end
        return invalid_plan("library walk is too large") if paths.size >= MAX_RELATIVE_FILES

        data["published_paths"] = paths + [ normalized ]
        new_raw = JSON.generate(data)
        scope = Download.where(id: download.id)
        scope = if raw.blank?
          scope.where(library_replacement_state: [ nil, "" ])
        else
          scope.where(library_replacement_state: raw)
        end
        updated = scope.update_all(library_replacement_state: new_raw, updated_at: Time.current)
        if updated == 1
          download.library_replacement_state = new_raw
          return true
        end
      end

      invalid_plan("published library file could not be recorded")
    rescue JSON::ParserError, ArgumentError, SystemCallError => error
      RemoteResult::Failed.new(error)
    end

    def forget_published_path!(download, path)
      normalized = Pathname(path.to_s).expand_path.to_s
      return invalid_plan("published path is blank") if normalized.blank?

      5.times do
        download.reload
        raw = download.library_replacement_state.to_s
        if raw.blank?
          download.library_replacement_state = nil
          return true
        end

        data = JSON.parse(raw)
        return invalid_plan("replacement plan is not an object") unless data.is_a?(Hash)

        paths = published_paths_from(data)
        return paths if RemoteResult.failed?(paths)
        unless paths.include?(normalized)
          download.library_replacement_state = raw
          return true
        end

        data["published_paths"] = paths - [ normalized ]
        new_raw = JSON.generate(data)
        updated = Download.where(id: download.id, library_replacement_state: raw).update_all(
          library_replacement_state: new_raw,
          updated_at: Time.current
        )
        if updated == 1
          download.library_replacement_state = new_raw
          return true
        end
      end

      invalid_plan("published library file could not be recorded")
    rescue JSON::ParserError, ArgumentError, SystemCallError => error
      RemoteResult::Failed.new(error)
    end

    # A finished import's files belong to the Book. Drop the publish journal
    # without deleting them.
    def release_publication!(download)
      download.reload
      state = load(download)
      return state if RemoteResult.failed?(state)
      return true unless state.is_a?(Publication)

      clear!(download, state.raw)
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
        published_paths: [],
        publications_recorded: false,
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
      unless plan.publications_recorded
        # Nothing was journaled, so the only candidate is the free path chosen
        # before publication. A reconstructed template path never reaches here.
        return remove_planned_paths!(book, plan)
      end

      removed = remove_published_files!(book, plan.published_paths, protected_path: plan.previous_path)
      return removed unless removed == true

      # The isolated folder is created before the first byte. Remove it only
      # once it no longer holds anything this import did not publish.
      prune_empty_ancestors!(book, File.join(plan.destination.to_s, "child"), plan.previous_path)
    end

    def remove_planned_paths!(book, plan)
      paths = [ plan.book_path, plan.destination ].compact.uniq.sort_by(&:length)
      decisions = paths.map { |path| removable_planned_path?(book, plan, path) }
      failed = decisions.find { |decision| RemoteResult.failed?(decision) }
      return failed if failed
      return false if decisions.any?(false)

      paths.zip(decisions).each do |path, decision|
        next if decision == :absent || decision == :retained

        deleted = delete_owned_path!(book, path)
        return deleted unless deleted == true
      end
      true
    end

    def removable_planned_path?(book, plan, path)
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
      return :retained if LibraryDestinationOccupancy.overlaps_acquired_book?(path, except_book_id: book.id)

      true
    end

    def publication_journal?(data)
      data["previous_path"].blank? &&
        data["destination"].blank? &&
        data["book_path"].blank? &&
        data["layout"].blank? &&
        data.key?("published_paths")
    end

    # A finished import already gave every journaled file to the Book,
    # including a sidecar that sits beside a single library file.
    def publication_retained?(download, book)
      download.post_processing_job_id.blank? && book.file_path.present?
    end

    def published_paths_not_referenced_by(book, paths)
      current = book.file_path.to_s
      return Array(paths) if current.blank?

      Array(paths).each_with_object([]) do |path, removable|
        referenced = SafeLibraryDeletionService.same_or_nested_path?(path, current)
        return referenced if RemoteResult.failed?(referenced)

        removable << path unless referenced == true
      end
    end

    def same_replacement_artifact?(candidate, artifact_id)
      artifact_id.present? && candidate.search_result_id == artifact_id
    end

    def published_paths_from(data)
      value = data["published_paths"]
      return [] if value.nil?
      return invalid_plan("replacement plan is incomplete") unless value.is_a?(Array)
      return invalid_plan("library walk is too large") if value.size > MAX_RELATIVE_FILES
      return invalid_plan("replacement plan is incomplete") unless value.all? { |path| path.is_a?(String) && path.present? }

      value
    end

    def remove_published_files!(book, paths, protected_path:)
      files = Array(paths).map(&:to_s).uniq
      files.each do |path|
        deleted = delete_published_file!(book, path, protected_path)
        return deleted unless deleted == true
      end
      files.each do |path|
        pruned = prune_empty_ancestors!(book, path, protected_path)
        return pruned unless pruned == true
      end
      true
    end

    def delete_published_file!(book, path, protected_path)
      decision = published_file_decision(book, path, protected_path)
      return decision if RemoteResult.failed?(decision) || decision == false
      return true if decision == :absent || decision == :directory || decision == :retained

      delete_owned_path!(book, path)
    end

    def published_file_decision(book, path, protected_path)
      existed = path_exists?(path)
      return existed if RemoteResult.failed?(existed)
      return :absent unless existed

      if protected_path.present?
        same = same_path?(path, protected_path)
        return same if RemoteResult.failed?(same)
        return false if same
        return false if SafeLibraryDeletionService.overlapping_library_paths?(path, protected_path)
      end

      root = output_root_for(book).to_s
      contained = inside_root?(path, root)
      return contained if RemoteResult.failed?(contained)
      return false unless contained

      root_match = same_path?(path, root)
      return root_match if RemoteResult.failed?(root_match)
      return false if root_match
      return :retained if LibraryDestinationOccupancy.overlaps_acquired_book?(path, except_book_id: book.id)

      return :directory if File.directory?(path) && !File.symlink?(path)

      true
    rescue SystemCallError => error
      RemoteResult::Failed.new(error)
    end

    def prune_empty_ancestors!(book, path, protected_path)
      root = output_root_for(book).to_s
      current = File.dirname(Pathname(path.to_s).expand_path.to_s)
      MAX_RELATIVE_FILES.times do
        root_match = same_path?(current, root)
        return root_match if RemoteResult.failed?(root_match)
        break if root_match

        contained = inside_root?(current, root)
        return contained if RemoteResult.failed?(contained)
        break unless contained

        if protected_path.present?
          same = same_path?(current, protected_path)
          return same if RemoteResult.failed?(same)
          break if same
          break if SafeLibraryDeletionService.overlapping_library_paths?(current, protected_path)
        end

        break if File.symlink?(current)

        existed = path_exists?(current)
        return existed if RemoteResult.failed?(existed)
        break unless existed
        break unless File.directory?(current)

        empty = empty_directory?(current)
        return empty if RemoteResult.failed?(empty)
        break unless empty
        break if LibraryDestinationOccupancy.overlaps_acquired_book?(current, except_book_id: book.id)

        deleted = delete_owned_path!(book, current)
        return deleted unless deleted == true

        parent = File.dirname(current)
        break if parent == current

        current = parent
      end
      true
    rescue ArgumentError, SystemCallError => error
      RemoteResult::Failed.new(error)
    end

    def empty_directory?(path)
      Dir.children(path).empty?
    rescue SystemCallError => error
      RemoteResult::Failed.new(error)
    end

    def attached_library_artifact?(path)
      return false if path.blank?

      File.exist?(path)
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
