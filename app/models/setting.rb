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
        Rails.logger.warn("Invalid JSON in setting '#{key}': #{value}")
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
        begin
          JSON.parse(new_value)
          new_value
        rescue JSON::ParserError
          # Not valid JSON: a comma-separated list becomes an array; one value is wrapped so JSON array fields stay arrays.
          if new_value.include?(',')
            new_value.split(',').map(&:strip).to_json
          else
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
