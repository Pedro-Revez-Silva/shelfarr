module Admin
  class UsersController < BaseController
    before_action :set_user, only: [:show, :edit, :update, :destroy, :directory_routing, :update_directory_routing]

    def index
      @users = User.active.order(created_at: :desc)
    end

    def show
    end

    def new
      @user = User.new
    end

    def create
      @user = User.new(user_params)

      if @user.save
        redirect_to admin_users_path, notice: "User was successfully created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      update_params = user_params
      update_params = update_params.except(:password, :password_confirmation) if update_params[:password].blank?

      if @user.update(update_params)
        redirect_to admin_users_path, notice: "User was successfully updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def directory_routing
    end

    def update_directory_routing
      if @user.update(directory_routing_params)
        redirect_to admin_users_path, notice: "Directory routing updated for #{@user.name}."
      else
        render :directory_routing, status: :unprocessable_entity
      end
    end

    def destroy
      if @user == Current.user
        redirect_to admin_users_path, alert: "You cannot delete yourself."
      else
        @user.soft_delete!
        redirect_to admin_users_path, notice: "User was successfully deleted."
      end
    end

    private

    def set_user
      @user = User.find(params[:id])
    end

    def user_params
      params.require(:user).permit(:name, :username, :password, :password_confirmation, :role)
    end

    def directory_routing_params
      params.require(:user).permit(:preferred_output_path, :library_routing_mode, :routing_layout)
    end
  end
end
