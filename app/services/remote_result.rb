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

    def empty?
      value.empty?
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

  Failed = Data.define(:error)

  def self.failed?(result)
    result.is_a?(Failed)
  end

  def self.succeeded?(result)
    !failed?(result) && result
  end
end
