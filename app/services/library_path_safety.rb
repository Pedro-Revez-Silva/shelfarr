# frozen_string_literal: true

require "pathname"

# Namespaces beneath a configured library root that are owned by Shelfarr's
# recovery machinery and must never be selected as library destinations.
class LibraryPathSafety
  INTERNAL_DIRECTORIES = %w[
    .shelfarr-staging
    .shelfarr-staging-v2
    .shelfarr-upload-staging
    .shelfarr-upload-zip-staging
  ].freeze
  INTERNAL_DIRECTORY_KEYS = INTERNAL_DIRECTORIES.map(&:downcase).freeze

  class << self
    def internal_relative_path?(path)
      first = Pathname(path.to_s).each_filename.first
      first.present? && INTERNAL_DIRECTORY_KEYS.include?(first.downcase)
    rescue ArgumentError
      false
    end

    def internal_path?(path, root:)
      expanded_root = Pathname(root).expand_path
      relative = Pathname(path).expand_path.relative_path_from(expanded_root)
      return false if relative.to_s == "." || relative.to_s == ".."
      return false if relative.to_s.start_with?("..#{File::SEPARATOR}")

      internal_relative_path?(relative)
    rescue ArgumentError
      false
    end

    def template_targets_internal_directory?(template)
      first = template.to_s.split(File::SEPARATOR).reject(&:blank?).first
      first.present? && INTERNAL_DIRECTORY_KEYS.include?(first.downcase)
    end
  end
end
