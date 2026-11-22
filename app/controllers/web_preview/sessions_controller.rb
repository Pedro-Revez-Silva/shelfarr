# frozen_string_literal: true

class WebPreview::SessionsController < WebPreview::APIController
  def show
    user = Current.user
    value = {
      account: { id: user.id.to_s, name: user.name },
      server: { name: request.host, version: Consumer::ServerInfo.server_version },
      links: { legacy_library: consumer_library_path, discover: helpers.discover_entry_path, requests: requests_path, account: profile_path },
      notifications: { url: notifications_path, unread: user.notifications.unread.count }
    }
    value[:admin] = { url: admin_root_path } if user.admin?
    value[:capabilities] = WebPreview::SessionCapabilities.for(user)
    render json: value
  end
end
