# frozen_string_literal: true

module WebPreview
  module ActivityFilters
    IDENTIFIER = /\A[1-9]\d{0,18}\z/
    DAY = /\A(\d{4})-(\d{2})-(\d{2})\z/
    MAX_ACTION = 200
    Invalid = Class.new(StandardError)

    module_function

    def parse(params)
      {
        user_id: strict(params[:user_id], :person),
        action: strict(params[:action_filter], :action),
        from: strict(params[:from], :day)
      }
    end

    def warm_address(params)
      {
        user: lenient(params[:user_id], :person),
        action: lenient(params[:action_filter], :action),
        from: lenient(params[:from], :day)
      }.compact
    end

    def strict(raw, check)
      return nil if raw.nil? || (raw.is_a?(String) && raw.blank?)

      (raw.is_a?(String) && public_send(check, raw)) || raise(Invalid)
    end

    def lenient(raw, check)
      public_send(check, raw) if raw.is_a?(String) && raw.present?
    end

    def person(value)
      value if value.match?(IDENTIFIER)
    end

    def action(value)
      value if value.length <= MAX_ACTION && value.valid_encoding?
    end

    def day(value)
      match = DAY.match(value)
      value if match && Date.valid_date?(*match.captures.map(&:to_i))
    end
  end
end
