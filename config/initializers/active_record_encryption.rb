# frozen_string_literal: true

# Note: The ActiveRecord encryption keys logic was moved to config/application.rb
# so that the environment variables are loaded before config/environments/production.rb
# runs, preventing KeyError crashes when booting Rails tasks in a production environment.
