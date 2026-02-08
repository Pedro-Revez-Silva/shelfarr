class API::V1::UsersController < API::V1::ApplicationController
  def create
    @user = User.new.tap do |u|
      u.name = params[:name]
      u.username = params[:username]
      u.password = params[:password]
      u.password_confirmation = params[:password]
    end

    if @user.save
      render json: @user.as_json(only: [ :id, :name, :username, :role, :updated_at, :created_at ]), status: :created
    else
      render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
