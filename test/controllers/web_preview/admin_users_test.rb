# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::AdminUsersTest < ActionDispatch::IntegrationTest
  include WebPreviewTestHelper

  NEW_PASSWORD = "Fresh-Secret-42xyz"
  OLD_PASSWORD = "Password123!"
  SENSITIVE_KEYS = %w[password_digest otp_secret backup_codes oidc_uid telegram_link_token_digest last_failed_login_ip password password_confirmation].freeze

  setup do
    @member = users(:one)
    @admin = users(:two)
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = [ @member, @admin ].map { |user| user.id.to_s }.join(",")
  end

  teardown do
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
  end

  def json_headers(user = @admin)
    account_headers(user).merge("Content-Type" => "application/json")
  end

  def admin_get(path, user: @admin)
    sign_in_as(user)
    preview_get path, user: user
    response.parsed_body
  end

  def read_user(user)
    admin_get(web_preview_api_admin_user_path(user)).fetch("user")
  end

  def write(method, path, body, user: @admin)
    public_send(method, path, params: body.to_json, headers: json_headers(user))
    response.parsed_body
  end

  def create_person(**overrides)
    body = { name: "Rowan Ash", username: "rowan", role: "member", password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD }.merge(overrides)
    write(:post, web_preview_api_admin_users_path, body)
  end

  def save_profile(user, version:, **values)
    body = { name: user.name, username: user.username, role: user.admin? ? "administrator" : "member", version: version }.merge(values)
    write(:put, web_preview_api_admin_user_path(user), body)
  end

  def snapshot(user)
    user.reload.attributes.slice("name", "username", "role", "password_digest", "deleted_at", "updated_at")
  end

  def other_person(username: "sage", role: :user)
    User.create!(name: username.capitalize, username: username, role: role, password: OLD_PASSWORD, password_confirmation: OLD_PASSWORD)
  end

  def write_requests(target)
    [
      [ :post, web_preview_api_admin_users_path, { name: "X", username: "intruder", role: "administrator", password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD } ],
      [ :put, web_preview_api_admin_user_path(target), { name: "Renamed", username: target.username, role: "administrator", version: "x" } ],
      [ :put, web_preview_api_admin_user_password_path(target), { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD } ],
      [ :post, web_preview_api_admin_user_remove_path(target), { version: "x" } ]
    ]
  end

  test "people are listed newest first with only what an administrator needs, and removed accounts are left out" do
    gone = other_person(username: "gone")
    gone.soft_delete!
    sage = other_person
    sage.update_columns(created_at: 1.minute.from_now)

    body = admin_get(web_preview_api_admin_users_path)

    assert_equal @admin.id.to_s, body.fetch("account")
    expected = [ sage, @admin, @member ].sort_by { |user| [ -user.created_at.to_f, -user.id ] }.map do |user|
      { "id" => user.id.to_s, "name" => user.name, "username" => user.username, "role" => user.admin? ? "administrator" : "member",
        "self" => user == @admin, "created_at" => user.created_at.iso8601(3) }
    end
    assert_equal expected, body.fetch("users")
    assert_equal "private, no-store", response.headers["Cache-Control"]
  end

  test "one person's record carries their requests, a version and the number of administrators" do
    record = admin_get(web_preview_api_admin_user_path(@member))

    assert_equal({ "id" => @member.id.to_s, "name" => "User One", "username" => "userone", "role" => "member", "self" => false,
      "created_at" => @member.created_at.iso8601(3), "requests" => @member.requests.count, "version" => record.dig("user", "version") }, record.fetch("user"))
    assert_match(/\A\h{24}\z/, record.dig("user", "version"))
    assert_equal 1, record.fetch("administrators")
    assert_equal true, read_user(@admin).fetch("self")
  end

  test "removed or unknown people answer not found without describing them" do
    gone = other_person(username: "gone")
    gone.soft_delete!
    sign_in_as(@admin)

    [ gone.id, User.maximum(:id) + 1 ].each do |id|
      preview_get web_preview_api_admin_user_path(id), user: @admin
      assert_response :not_found
      assert_equal({ "error" => "user_not_found" }, response.parsed_body)
    end
    before = snapshot(gone)
    assert_equal({ "error" => "user_not_found" }, save_profile(gone, version: "x", name: "Back"))
    assert_response :not_found
    write(:put, web_preview_api_admin_user_password_path(gone), { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD })
    assert_response :not_found
    write(:post, web_preview_api_admin_user_remove_path(gone), { version: "x" })
    assert_response :not_found
    assert_equal before, snapshot(gone)
  end

  test "with the preview off, for someone not on its list, for members and when signed out, nothing is shown or changed" do
    target = other_person
    before = snapshot(target)

    sign_in_as(@admin)
    with_env(WebPreview::Access::VARIABLE => nil) do
      preview_get web_preview_api_admin_users_path, user: @admin
      assert_response :not_found
      write_requests(target).each { |method, path, body| write(method, path, body); assert_response :not_found }
      get web_preview_server_person_path(target)
      assert_response :not_found
    end
    with_env(WebPreview::Access::VARIABLE => @member.id.to_s) do
      preview_get web_preview_api_admin_users_path, user: @admin
      assert_response :not_found
      write_requests(target).each { |method, path, body| write(method, path, body); assert_response :not_found }
    end

    sign_in_as(@member)
    preview_get web_preview_api_admin_users_path, user: @member
    assert_equal({ "error" => "not_found" }, response.parsed_body)
    preview_get web_preview_api_admin_user_path(target), user: @member
    assert_response :not_found
    write_requests(target).each { |method, path, body| write(method, path, body, user: @member); assert_response :not_found }

    sign_out
    preview_get web_preview_api_admin_users_path, user: @admin
    assert_response :unauthorized
    write_requests(target).each { |method, path, body| write(method, path, body); assert_response :unauthorized }

    assert_equal before, snapshot(target)
    assert_nil User.find_by(username: "intruder")
  end

  test "a request made for another account, or without the page's token, changes nothing" do
    target = other_person
    before = snapshot(target)
    sign_in_as(@admin)

    write_requests(target).each do |method, path, body|
      public_send(method, path, params: body.to_json, headers: json_headers(@member))
      assert_response :unauthorized
      assert_equal "account_changed", response.parsed_body.fetch("error")
    end
    with_forgery_protection do
      write_requests(target).each do |method, path, body|
        write(method, path, body)
        assert_response :unprocessable_entity
        assert_equal "invalid_csrf", response.parsed_body.fetch("error")
      end
    end

    assert_equal before, snapshot(target)
    assert_nil User.find_by(username: "intruder")
  end

  test "adding a person saves exactly what the classic form saves" do
    sign_in_as(@admin)

    body = create_person(username: "  Rowan  ", role: "administrator")

    assert_response :created
    rowan = User.find_by!(username: "rowan")
    assert_equal [ "Rowan Ash", "admin", nil ], [ rowan.name, rowan.role, rowan.deleted_at ]
    assert rowan.authenticate(NEW_PASSWORD)
    assert_equal({ "id" => rowan.id.to_s, "name" => "Rowan Ash", "username" => "rowan", "role" => "administrator", "self" => false,
      "created_at" => rowan.created_at.iso8601(3), "requests" => 0, "version" => body.dig("user", "version") }, body.fetch("user"))
    assert_equal 2, body.fetch("administrators")

    create_person(name: "Member", username: "member_two")
    assert User.find_by!(username: "member_two").user?
  end

  test "a username of a removed account can be used again, as on the classic form" do
    other_person(username: "rowan").soft_delete!
    sign_in_as(@admin)

    create_person

    assert_response :created
    assert_equal 1, User.active.where(username: "rowan").count
  end

  test "an add the User rules refuse answers each field's messages and creates nobody" do
    sign_in_as(@admin)
    cases = {
      { username: "Admin" } => { "username" => [ "has already been taken" ] },
      { username: "no spaces!" } => { "username" => [ "only allows lowercase letters, numbers, and underscores" ] },
      { name: "" } => { "name" => [ "can't be blank" ] },
      { password: "short", password_confirmation: "short" } => { "password" => [ "is too short (minimum is 12 characters)", "must include at least one lowercase letter, one uppercase letter, and one number" ] },
      { password_confirmation: "Different-Secret-42" } => { "password_confirmation" => [ "doesn't match Password" ] },
      { password: "", password_confirmation: "" } => { "password" => [ "can't be blank" ] }
    }

    cases.each do |overrides, errors|
      assert_no_difference -> { User.count }, overrides.inspect do
        body = create_person(**overrides)
        assert_response :unprocessable_entity
        assert_equal({ "account" => @admin.id.to_s, "error" => "invalid_user", "errors" => errors }, body, overrides.inspect)
      end
    end
  end

  test "values that are not text, or a role that does not exist, are refused before anything is saved" do
    target = other_person
    before = snapshot(target)
    sign_in_as(@admin)

    [ { role: "owner" }, { role: "admin" }, { role: nil }, { name: 5 }, { username: [ "rowan" ] }, { password: { "a" => 1 } } ].each do |overrides|
      assert_no_difference -> { User.count } do
        create_person(**overrides)
      end
      assert_response :bad_request, overrides.inspect
    end
    version = read_user(target).fetch("version")
    [ { role: "superuser" }, { name: nil }, { version: 3 } ].each do |overrides|
      save_profile(target, version: version, **overrides)
      assert_response :bad_request, overrides.inspect
    end
    write(:put, web_preview_api_admin_user_password_path(target), { password: NEW_PASSWORD })
    assert_response :bad_request
    write(:post, web_preview_api_admin_user_remove_path(target), {})
    assert_response :bad_request

    assert_equal before, snapshot(target)
  end

  test "saving name, username and role changes only those, with the version that was read" do
    target = other_person
    digest = target.password_digest
    version = read_user(target).fetch("version")

    body = save_profile(target, version: version, name: "Sage Green", username: "Sage_G", role: "administrator")

    assert_response :success
    target.reload
    assert_equal [ "Sage Green", "sage_g", "admin", digest ], [ target.name, target.username, target.role, target.password_digest ]
    assert_equal "administrator", body.dig("user", "role")
    assert_not_equal version, body.dig("user", "version")
    assert_equal 2, body.fetch("administrators")
  end

  test "a save made against an older read is refused with what the server has now, and changes nothing" do
    target = other_person
    read = read_user(target)
    target.update!(name: "Changed Elsewhere")
    before = snapshot(target)

    body = save_profile(target, version: read.fetch("version"), name: "Mine", role: "administrator")

    assert_response :conflict
    assert_equal "user_changed", body.fetch("error")
    assert_equal "Changed Elsewhere", body.dig("user", "name")
    assert_equal read_user(target).fetch("version"), body.dig("user", "version")
    assert_equal before, snapshot(target)
  end

  test "a failed sign-in by the person does not count as a change to their record" do
    target = other_person
    version = read_user(target).fetch("version")
    target.record_failed_login!("192.0.2.7")

    save_profile(target, version: version, name: "Still Mine")

    assert_response :success
    assert_equal "Still Mine", target.reload.name
  end

  test "a save the User rules refuse answers the field messages and keeps the stored values" do
    target = other_person
    before = snapshot(target)
    version = read_user(target).fetch("version")

    body = save_profile(target, version: version, username: "userone", name: " ")

    assert_response :unprocessable_entity
    assert_equal({ "name" => [ "can't be blank" ], "username" => [ "has already been taken" ] }, body.fetch("errors"))
    assert_equal before, snapshot(target)
  end

  test "an administrator who is made a member meanwhile can no longer read or change anyone" do
    target = other_person
    version = read_user(target).fetch("version")
    @admin.update!(role: :user)
    before = snapshot(target)

    save_profile(target, version: version, role: "administrator")
    assert_response :not_found
    assert_equal "not_found", response.parsed_body.fetch("error")
    write(:post, web_preview_api_admin_user_remove_path(target), { version: version })
    assert_response :not_found

    assert_equal before, snapshot(target)
  end

  test "an administrator may change their own role, as on the classic form, and then loses access" do
    other_person(username: "boss", role: :admin)
    version = read_user(@admin).fetch("version")

    body = save_profile(@admin, version: version, role: "member")

    assert_response :success
    assert_equal [ "member", true, 1 ], [ body.dig("user", "role"), body.dig("user", "self"), body.fetch("administrators") ]
    assert @admin.reload.user?
    preview_get web_preview_api_admin_users_path, user: @admin
    assert_response :not_found
  end

  test "an administrator who is removed meanwhile is signed out and changes nothing" do
    target = other_person
    version = read_user(target).fetch("version")
    @admin.soft_delete!
    before = snapshot(target)

    save_profile(target, version: version, name: "Mine")

    assert_response :unauthorized
    assert_equal before, snapshot(target)
  end

  test "setting someone's password works with the same rules and keeps them signed in, as on the classic form" do
    target = other_person
    target_session = target.sessions.create!
    sign_in_as(@admin)

    body = write(:put, web_preview_api_admin_user_password_path(target), { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD })

    assert_response :success
    assert target.reload.authenticate(NEW_PASSWORD)
    assert_not target.authenticate(OLD_PASSWORD)
    assert Session.exists?(target_session.id)
    assert_equal target.id.to_s, body.dig("user", "id")
  end

  test "a password the rules refuse, or a blank one, is answered field by field and the old one keeps working" do
    target = other_person
    sign_in_as(@admin)
    cases = {
      [ "", "" ] => { "password" => [ "can't be blank" ] },
      [ "lowercaseonly1234", "lowercaseonly1234" ] => { "password" => [ "must include at least one lowercase letter, one uppercase letter, and one number" ] },
      [ NEW_PASSWORD, "Something-Else-99" ] => { "password_confirmation" => [ "doesn't match Password" ] },
      [ "#{'Aa1' * 30}", "#{'Aa1' * 30}" ] => { "password" => [ "is too long" ] }
    }

    cases.each do |(password, confirmation), errors|
      body = write(:put, web_preview_api_admin_user_password_path(target), { password: password, password_confirmation: confirmation })
      assert_response :unprocessable_entity
      assert_equal({ "account" => @admin.id.to_s, "error" => "invalid_user", "errors" => errors }, body, errors.inspect)
    end
    assert target.reload.authenticate(OLD_PASSWORD)
  end

  test "an administrator's own password and own account stay with Account" do
    sign_in_as(@admin)
    before = snapshot(@admin)

    body = write(:put, web_preview_api_admin_user_password_path(@admin), { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD })
    assert_response :unprocessable_entity
    assert_equal({ "account" => @admin.id.to_s, "error" => "own_account", "message" => "Change your own password in Account, under Sign-in and security." }, body)

    body = write(:post, web_preview_api_admin_user_remove_path(@admin), { version: read_user(@admin).fetch("version") })
    assert_response :unprocessable_entity
    assert_equal({ "account" => @admin.id.to_s, "error" => "own_account", "message" => "You cannot remove your own account." }, body)

    assert_equal before, snapshot(@admin)
    assert @admin.authenticate(OLD_PASSWORD)
  end

  test "removing a person uses the classic soft removal and they disappear from the list" do
    target = other_person
    target.sessions.create!
    token, = APIToken.issue!(name: "Phone", user: target, scopes: [ "search:read" ])
    version = read_user(target).fetch("version")

    body = write(:post, web_preview_api_admin_user_remove_path(target), { version: version })

    assert_response :success
    assert_equal({ "account" => @admin.id.to_s, "removed" => target.id.to_s }, body)
    target.reload
    assert target.deleted?
    assert_equal 0, target.sessions.count
    assert token.reload.revoked_at.present?
    assert_not_includes admin_get(web_preview_api_admin_users_path).fetch("users").map { |user| user.fetch("id") }, target.id.to_s
  end

  test "a removal confirmed against an older read is refused with the current record" do
    target = other_person
    version = read_user(target).fetch("version")
    target.update!(username: "renamed")

    body = write(:post, web_preview_api_admin_user_remove_path(target), { version: version })

    assert_response :conflict
    assert_equal [ "user_changed", "renamed" ], [ body.fetch("error"), body.dig("user", "username") ]
    assert_not target.reload.deleted?
  end

  test "passwords are never answered back or written to the log" do
    target = other_person
    log = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    ActionController::Base.logger = Rails.logger
    begin
      sign_in_as(@admin)
      answers = []
      answers << create_person(password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD)
      answers << create_person(username: "other_one", password: "#{NEW_PASSWORD}-weak", password_confirmation: "#{NEW_PASSWORD}-mismatch")
      answers << write(:put, web_preview_api_admin_user_password_path(target), { password: "#{NEW_PASSWORD}-set", password_confirmation: "#{NEW_PASSWORD}-set" })
      answers << write(:put, web_preview_api_admin_user_password_path(target), { password: "short-secret", password_confirmation: "short-secret" })
      answers << admin_get(web_preview_api_admin_users_path)
      answers << admin_get(web_preview_api_admin_user_path(target))
    ensure
      Rails.logger = previous
      ActionController::Base.logger = previous
    end

    text = answers.to_json
    [ NEW_PASSWORD, "short-secret", target.reload.password_digest ].each do |secret|
      assert_not_includes text, secret
      assert_not_includes log.string, secret
    end
    keys = answers.flat_map { |answer| [ answer["user"], *answer["users"] ].compact.flat_map(&:keys) }
    assert_empty keys & SENSITIVE_KEYS
    assert_includes log.string, "WebPreview::Admin::UsersController#create"
  end

  test "the people pages open in the preview for its administrators" do
    sign_in_as(@admin)
    [ web_preview_server_category_path(category: "people"), web_preview_server_new_person_path, web_preview_server_person_path(@member) ].each do |path|
      get path
      assert_response :success, path
      assert_select "#shelfarr-boot"
    end
  end

  test "old user addresses open the matching preview page for its administrators" do
    gone = other_person(username: "gone")
    gone.soft_delete!
    sign_in_as(@admin)

    get admin_users_path
    assert_redirected_to web_preview_server_category_path(category: "people", anchor: "users")
    get new_admin_user_path
    assert_redirected_to web_preview_server_new_person_path
    get admin_user_path(@member)
    assert_redirected_to web_preview_server_person_path(@member)
    get edit_admin_user_path(@member)
    assert_redirected_to web_preview_server_person_path(@member)

    get admin_user_path(gone)
    assert_response :success
    assert_select "h1", "Gone"
    get "/admin/users", env: { "SCRIPT_NAME" => "/shelf" }
    assert_redirected_to "http://www.example.com/shelf/preview/server/people#users"
    get "/admin/users/#{@member.id}/edit", env: { "SCRIPT_NAME" => "/shelf" }
    assert_redirected_to "http://www.example.com/shelf/preview/server/people/users/#{@member.id}"
  end

  test "old user addresses stay classic with the preview off, for unlisted administrators, without the stylesheet and after a classic form" do
    sign_in_as(@admin)

    with_env(WebPreview::Access::VARIABLE => nil) do
      get admin_users_path
      assert_response :success
      assert_select "h1", "Users"
    end
    with_env(WebPreview::Access::VARIABLE => @member.id.to_s) do
      get edit_admin_user_path(@member)
      assert_response :success
      assert_select "h1", "Edit User"
    end
    WarmEntry.stub(:stylesheet_built?, false) do
      get new_admin_user_path
      assert_response :success
      assert_select "h1", "New User"
    end

    post admin_users_path, params: { user: { name: "Classic", username: "classic", role: "user", password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD } }
    assert_redirected_to admin_users_path
    follow_redirect!
    assert_response :success
    assert_select "h1", "Users"
    assert_select "td", "classic"

    delete admin_user_path(@admin)
    follow_redirect!
    assert_response :success
    assert_not @admin.reload.deleted?

    sign_in_as(@member)
    get admin_users_path
    assert_redirected_to root_path
  end
end
