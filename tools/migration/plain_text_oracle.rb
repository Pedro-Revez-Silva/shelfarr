# frozen_string_literal: true

require "json"
require "cgi"
require "rails-html-sanitizer"

load File.expand_path("../../app/services/web_preview/publication_json.rb", __dir__)

corpus = JSON.parse(File.read(ARGV.fetch(0)))
renderer = WebPreview::PublicationJson.allocate
expected = corpus.map do |entry|
  { "text" => renderer.send(:plain_text, entry) }
rescue StandardError => error
  { "error" => error.class.name }
end
puts JSON.pretty_generate(expected)
