class UploadPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    user.present?
  end

  def new?
    user.present? && (admin? || SettingsService.user_uploads_allowed?)
  end

  def create?
    new?
  end

  def destroy?
    admin?
  end

  def retry?
    admin?
  end

  class Scope < Scope
    def resolve
      return scope.none unless user
      scope.includes(:user, :book).recent
    end
  end
end
