module Admin
  class UsersController < BaseController
    before_action :set_user, only: [:show, :edit, :update, :destroy, :library_routing, :update_library_routing]

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

    def library_routing
    end

    def update_library_routing
      if @user.update(library_routing_params)
        redirect_to library_routing_admin_user_path(@user), notice: "Library routing updated."
      else
        render :library_routing, status: :unprocessable_entity
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

    def library_routing_params
      params.require(:user).permit(
        :preferred_audiobook_library_id,
        :preferred_ebook_library_id,
        :preferred_comicbook_library_id
      )
    end
  end
end
