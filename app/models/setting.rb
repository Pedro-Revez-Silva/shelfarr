class Setting < ApplicationRecord
  VALID_TYPES = %w[string integer boolean json].freeze

  validates :key, presence: true, uniqueness: true
  validates :value_type, inclusion: { in: VALID_TYPES }

  def typed_value
    return nil if value.nil?

    case value_type
    when "string"
      value
    when "integer"
      value.to_i
    when "boolean"
      ActiveModel::Type::Boolean.new.cast(value)
    when "json"
      begin
        JSON.parse(value)
      rescue JSON::ParserError
        # Handle corrupted JSON data by attempting to fix it
        Rails.logger.warn("Invalid JSON in setting '#{key}': #{value}")
        # Try to wrap single values in an array for consistency
        if value.include?(',')
          value.split(',').map(&:strip)
        else
          [ value ]
        end
      end
    else
      value
    end
  end

  def typed_value=(new_value)
    self.value = case value_type
    when "json"
      if new_value.is_a?(String)
        # Check if it's already valid JSON
        begin
          JSON.parse(new_value)
          new_value # It's valid JSON, use as-is
        rescue JSON::ParserError
          # Not valid JSON - try to convert intelligently
          # If it looks like a comma-separated list, convert to array
          if new_value.include?(',')
            new_value.split(',').map(&:strip).to_json
          else
            # Single value - wrap in array for consistency with JSON array fields
            [ new_value ].to_json
          end
        end
      else
        new_value.to_json
      end
    else
      new_value.to_s
    end
  end
end
