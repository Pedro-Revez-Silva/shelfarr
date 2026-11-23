# frozen_string_literal: true

module WebPreview
  module ActivityFilters
    IDENTIFIER = /\A[1-9]\d{0,18}\z/
    PADDED_IDENTIFIER = /\A0*([1-9]\d{0,18})\z/
    DAY = /\A(\d{4})-(\d{2})-(\d{2})\z/
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
      carried = { user: [ params[:user_id], :listed_person ], action: [ params[:action_filter], :action ], from: [ params[:from], :day ] }
      carried.each_with_object({}) do |(name, (raw, check)), address|
        next if raw.blank?
        return nil unless raw.is_a?(String) && (value = public_send(check, raw))

        address[name] = value
      end
    end

    def strict(raw, check)
      return nil if raw.nil? || (raw.is_a?(String) && raw.blank?)

      (raw.is_a?(String) && public_send(check, raw)) || raise(Invalid)
    end

    def person(value)
      value if value.match?(IDENTIFIER)
    end

    def listed_person(value)
      PADDED_IDENTIFIER.match(value)&.captures&.first
    end

    def action(value)
      value
    end

    def day(value)
      match = DAY.match(value)
      value if match && Date.valid_date?(*match.captures.map(&:to_i))
    end
  end
end
