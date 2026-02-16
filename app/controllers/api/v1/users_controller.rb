class API::V1::UsersController < API::V1::ApplicationController
  def create
    user = User.new(user_params)

    if user.save
      render json: user_payload(user), status: :created
    else
      render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def user_params
    attributes = params.permit(:name, :username, :password)
    attributes.merge(password_confirmation: attributes[:password])
  end

  def user_payload(user)
    user.as_json(only: [ :id, :name, :username, :role, :updated_at, :created_at ])
  end
end
