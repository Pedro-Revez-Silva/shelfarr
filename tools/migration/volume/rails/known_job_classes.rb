require "json"

Rails.application.eager_load!
names = ActiveJob::Base.descendants.filter_map(&:name).sort
puts "M2-RESULT #{JSON.generate(names)}"
