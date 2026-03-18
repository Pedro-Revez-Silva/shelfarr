module Authorization
  extend ActiveSupport::Concern

  included do
    helper_method :allowed_to?
  end

  private

  def allowed_to?(query, record)
    policy_for(record).public_send(query)
  end

  def authorize!(query, record, fallback_location:, alert:)
    return true if allowed_to?(query, record)

    redirect_to fallback_location, alert: alert
    false
  end

  def policy_scope(scope)
    policy_for(scope).scope.resolve
  end

  def policy_for(record)
    policy_class_for(record).new(Current.user, record)
  end

  def policy_class_for(record)
    record_class = record.is_a?(Class) ? record : record.class
    "#{record_class}Policy".constantize
  end
end
