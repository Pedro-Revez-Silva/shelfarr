# frozen_string_literal: true

module WebPreviewTestHelper
  WEB_ROOT = Rails.root.join("apps/web")
  BUILD = Rails.root.join("app/assets/builds/web/preview.js")

  def self.ensure_built
    return if BUILD.exist?

    system("bun", "install", "--frozen-lockfile", chdir: WEB_ROOT.to_s) &&
      system("bun", "run", "build", chdir: WEB_ROOT.to_s) &&
      BUILD.exist? or abort("Build the web preview first: cd apps/web && bun install --frozen-lockfile && bun run build")
  end

  ensure_built

  def with_preview_users(*users, &block)
    with_env({ WebPreview::Access::VARIABLE => users.map(&:id).join(",") }, &block)
  end

  def account_headers(user)
    { "X-Shelfarr-Account" => user.id.to_s, "Accept" => "application/json" }
  end

  def preview_get(path, user: users(:one), headers: {})
    get path, headers: account_headers(user).merge(headers)
  end

  def with_forgery_protection
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  def csrf_token
    get web_preview_library_path
    css_select("meta[name=csrf-token]").sole["content"]
  end
end
