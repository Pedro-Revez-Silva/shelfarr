module Admin
  class UsersController < BaseController
    before_action :set_user, only: [:show, :edit, :update, :destroy]
    before_action :open_warm_page, only: [:index, :new, :show, :edit]

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

    def open_warm_page
      return unless flash.empty? && WebPreview::Access.current.allows?(Current.user) && WarmEntry.stylesheet_built?

      target = warm_page
      redirect_to target if target
    end

    def warm_page
      case action_name
      when "index" then web_preview_server_category_path(category: "people", anchor: "users")
      when "new" then web_preview_server_new_person_path
      else web_preview_server_person_path(@user) unless @user.deleted?
      end
    end

    def user_params
      params.require(:user).permit(:name, :username, :password, :password_confirmation, :role)
    end
  end
end
