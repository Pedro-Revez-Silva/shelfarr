# frozen_string_literal: true

module RemoteResult
  Ok = Data.define(:value) do
    def size
      value.size
    end

    def first(...)
      value.first(...)
    end

    def last(...)
      value.last(...)
    end

    def pluck(...)
      value.pluck(...)
    end
  end

  Empty = Data.define do
    def value
      []
    end

    def empty?
      true
    end

    def size
      0
    end
  end

  Failed = Data.define(:error) do
    def to_s
      raise TypeError, "no implicit conversion of RemoteResult::Failed into String"
    end

    def to_str
      to_s
    end

    def to_ary
      raise TypeError, "no implicit conversion of RemoteResult::Failed into Array"
    end

    def to_a
      to_ary
    end
  end

  def self.failed?(result)
    result.is_a?(Failed)
  end

  def self.succeeded?(result)
    return false if result == []

    !failed?(result) && result
  end
end
