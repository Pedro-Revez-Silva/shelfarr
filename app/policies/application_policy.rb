class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def self.scope
    Scope
  end

  def scope
    self.class::Scope.new(user, policy_scope_target)
  end

  private

  def admin?
    user&.admin?
  end

  def policy_scope_target
    record.is_a?(Class) ? record : record.class
  end

  class Scope
    attr_reader :user, :scope

    def initialize(user, scope)
      @user = user
      @scope = scope
    end
  end
end
