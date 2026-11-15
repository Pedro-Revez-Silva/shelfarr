# frozen_string_literal: true

require "json"
require "active_support/all"

load File.expand_path("../../app/services/audiobookshelf_client.rb", __dir__)

corpus = JSON.parse(File.read(ARGV.fetch(0)))
expected = corpus.map do |entry|
  AudiobookshelfClient.send(:extract_library_items, { "results" => [ entry["raw"] ] }).first
end
puts JSON.pretty_generate(expected)
