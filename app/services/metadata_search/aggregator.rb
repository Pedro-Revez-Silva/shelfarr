# frozen_string_literal: true

module MetadataSearch
  class Aggregator
    class << self
      def call(results, priority: [], requested_content_kind: nil)
        new(results, priority: priority, requested_content_kind: requested_content_kind).call
      end
    end

    def initialize(results, priority: [], requested_content_kind: nil)
      @results = Array(results).compact
      @priority = Array(priority).map(&:to_s)
      @requested_content_kind = ContentKinds.normalize(requested_content_kind, default: nil)
    end

    def call
      clusters.map { |cluster| candidate_for(cluster) }
    end

    private

    attr_reader :results, :priority, :requested_content_kind

    def clusters
      results.each_with_object([]) do |result, groups|
        group = groups.find do |candidate_group|
          candidate_group.any? { |member| match?(member, result) } &&
            candidate_group.none? { |member| classification_conflict?(member, result) }
        end
        group ? group << result : groups << [ result ]
      end
    end

    def match?(left, right)
      return false if left.resource_kind.to_s != right.resource_kind.to_s
      return false if classification_conflict?(left, right)
      return true if shared_isbn?(left, right)
      return false if conflicting_isbn?(left, right)
      return false unless normalized_text(left.title) == normalized_text(right.title)

      left_author = normalized_text(left.author)
      right_author = normalized_text(right.author)
      return false if left_author.blank? || right_author.blank?
      return false unless left_author == right_author

      close_year?(left.year, right.year)
    end

    def shared_isbn?(left, right)
      (isbns(left) & isbns(right)).any?
    end

    def conflicting_isbn?(left, right)
      left_isbns = isbns(left)
      right_isbns = isbns(right)
      left_isbns.any? && right_isbns.any? && (left_isbns & right_isbns).empty?
    end

    def isbns(result)
      [ result.isbn_10, result.isbn_13 ].compact.map { |isbn| isbn.to_s.delete(" -") }.reject(&:blank?)
    end

    def normalized_text(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
    end

    def close_year?(left_year, right_year)
      return true if left_year.blank? || right_year.blank?

      (left_year.to_i - right_year.to_i).abs <= 1
    end

    def classification_conflict?(left, right)
      return false if left.content_kind == right.content_kind

      strong_classification?(left) && strong_classification?(right)
    end

    def strong_classification?(result)
      result.classification_confidence.to_i >= ContentClassifier::STRONG_CONFIDENCE
    end

    def candidate_for(group)
      ordered = group.sort_by { |result| provider_rank(result.source) }
      primary = ordered.first
      classification = classification_for(ordered)

      Candidate.new(
        canonical_key: canonical_key_for(group),
        title: first_present(ordered, :title),
        author: first_present(ordered, :author),
        year: first_present(ordered, :year),
        description: first_present(ordered, :description),
        cover_url: first_present(ordered, :cover_url),
        series_name: first_present(ordered, :series_name),
        series_position: first_present(ordered, :series_position),
        has_ebook: any_truthy?(group, :has_ebook),
        has_audiobook: any_truthy?(group, :has_audiobook),
        sources: ordered.map { |result| source_entry(result) },
        editions: edition_entries(group, primary),
        confidence: confidence_for(group),
        content_kind: classification[:content_kind],
        resource_kind: first_present(ordered, :resource_kind) || "work",
        classification_evidence: classification[:evidence],
        classification_confidence: classification[:confidence],
        categories: group.flat_map(&:categories).compact_blank.uniq,
        subjects: group.flat_map(&:subjects).compact_blank.uniq,
        collection_source: first_present(ordered, :collection_source),
        collection_id: first_present(ordered, :collection_id),
        collection_title: first_present(ordered, :collection_title),
        issue_number: first_present(ordered, :issue_number),
        release_date: first_present(ordered, :release_date)
      )
    end

    def canonical_key_for(group)
      isbn = group.flat_map { |result| isbns(result) }.first
      return "isbn:#{isbn}" if isbn.present?

      primary = group.min_by { |result| provider_rank(result.source) }
      primary.work_id
    end

    def first_present(group, field)
      group.map { |result| result.public_send(field) }.find(&:present?)
    end

    def any_truthy?(group, field)
      return true if group.any? { |result| result.public_send(field) == true }
      return false if group.any? { |result| result.public_send(field) == false }

      nil
    end

    def classification_for(ordered)
      strongest = ordered.max_by { |result| result.classification_confidence.to_i }
      confidence = strongest.classification_confidence.to_i
      requested_fallback = requested_content_kind && confidence < ContentClassifier::STRONG_CONFIDENCE
      content_kind = if requested_fallback
        requested_content_kind
      else
        strongest.content_kind
      end
      evidence = ordered.flat_map(&:classification_evidence).compact_blank.uniq
      evidence << "requested_kind:#{requested_content_kind}" if requested_fallback

      {
        content_kind: ContentKinds.normalize(content_kind),
        confidence: confidence,
        evidence: evidence.uniq
      }
    end

    def source_entry(result)
      {
        source: result.source,
        source_id: result.source_id,
        source_name: result.source_name,
        source_url: result.source_url,
        work_id: result.work_id
      }
    end

    def edition_entries(group, primary)
      group.reject { |result| result == primary }.map do |result|
        {
          source: result.source,
          source_id: result.source_id,
          isbn_10: result.isbn_10,
          isbn_13: result.isbn_13,
          publisher: result.publisher,
          year: result.year,
          page_count: result.page_count,
          resource_kind: result.resource_kind
        }.compact
      end
    end

    def confidence_for(group)
      return 100 if group.size > 1 && group.any? { |result| isbns(result).any? }
      return 90 if group.size > 1

      70
    end

    def provider_rank(source)
      priority.index(source.to_s) || priority.size
    end
  end
end
