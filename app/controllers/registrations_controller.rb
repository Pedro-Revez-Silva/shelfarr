class RegistrationsController < ApplicationController
  allow_unauthenticated_access only: [:new, :create]

  before_action :require_admin_for_new_users, only: [:new, :create]

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params)

    if @user.save
      if first_user?
        start_new_session_for(@user)
        redirect_to admin_settings_path, notice: "Welcome! You are the admin. Please configure your settings."
      else
        redirect_to admin_users_path, notice: "User created successfully."
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def user_params
    if Current.user&.admin?
      params.require(:user).permit(:name, :username, :password, :password_confirmation, :role)
    else
      params.require(:user).permit(:name, :username, :password, :password_confirmation)
    end
  end

  def first_user?
    User.active.count == 1 && @user == User.active.first
  end

  def require_admin_for_new_users
    return if User.active.none?
    return if authenticated? && Current.user&.admin?

    redirect_to root_path, alert: "Only admins can create new users."
  end
end
