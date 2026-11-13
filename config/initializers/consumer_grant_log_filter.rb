# frozen_string_literal: true

require_relative "../../lib/consumer_grant_log_filter"
ActionDispatch::Request.prepend(ConsumerGrantLogFilter)
