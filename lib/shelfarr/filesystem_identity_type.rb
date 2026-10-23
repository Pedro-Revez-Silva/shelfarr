# frozen_string_literal: true

module Shelfarr
  # st_dev and st_ino are unsigned 64-bit. SQLite integers are signed, so the
  # upper half cannot be stored as integers. Decimal text keeps every value,
  # and reads come back as integers so identity checks stay exact.
  class FilesystemIdentityType < ActiveRecord::Type::Value
    def type
      :string
    end

    def serialize(value)
      integer = cast(value)
      integer&.to_s
    end

    def serialize_cast_value(value)
      value&.to_s
    end

    private

    def cast_value(value)
      case value
      when Integer
        value
      when String
        return if value.empty?

        Integer(value, 10)
      else
        Integer(value)
      end
    end
  end
end
