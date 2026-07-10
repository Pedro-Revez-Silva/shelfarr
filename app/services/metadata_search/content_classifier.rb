# frozen_string_literal: true

module MetadataSearch
  class ContentClassifier
    STRONG_CONFIDENCE = 80
    GRAPHIC_CONFIDENCE = 90
    PROVIDER_CONFIDENCE = 100
    FALLBACK_CONFIDENCE = 20
    DEFAULT_CONFIDENCE = 10

    GRAPHIC_PATTERN = /\b(?:manga|graphic novels?|comics?)\b/i

    Classification = Data.define(:content_kind, :confidence, :evidence)

    class << self
      def call(source:, categories: [], subjects: [], requested_content_kind: nil)
        return classification(ContentKinds::GRAPHIC, PROVIDER_CONFIDENCE, [ "provider:comic_vine" ]) if source.to_s == "comic_vine"

        evidence = graphic_evidence(categories, "category") + graphic_evidence(subjects, "subject")
        return classification(ContentKinds::GRAPHIC, GRAPHIC_CONFIDENCE, evidence) if evidence.any?

        requested = ContentKinds.normalize(requested_content_kind, default: nil)
        if requested
          classification(requested, FALLBACK_CONFIDENCE, [ "requested_kind:#{requested}" ])
        else
          classification(ContentKinds::BOOK, DEFAULT_CONFIDENCE, [ "default:book" ])
        end
      end

      private

      def graphic_evidence(values, label)
        Array(values).filter_map do |value|
          text = value.to_s.squish
          normalized = text.downcase.gsub(/[^a-z0-9]+/, " ").squish
          "#{label}:#{text}" if normalized.match?(GRAPHIC_PATTERN)
        end
      end

      def classification(content_kind, confidence, evidence)
        Classification.new(content_kind: content_kind, confidence: confidence, evidence: evidence.freeze)
      end
    end
  end
end
