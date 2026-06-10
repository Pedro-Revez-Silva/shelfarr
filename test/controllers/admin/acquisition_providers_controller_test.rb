# frozen_string_literal: true

require "test_helper"

class Admin::AcquisitionProvidersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:two))
  end

  test "index renders providers ordered by priority" do
    second = create_provider(name: "Second Provider", url: "http://second-provider.test", priority: 1)
    first = create_provider(name: "First Provider", url: "http://first-provider.test", priority: 0)

    get admin_acquisition_providers_url

    assert_response :success
    assert_select "h1", "Acquisition Providers"
    assert_select "tbody tr:first-child td", text: first.name
    assert_select "tbody tr:last-child td", text: second.name
  end

  test "new renders form with defaults" do
    get new_admin_acquisition_provider_url

    assert_response :success
    assert_select "form[action='#{admin_acquisition_providers_path}']"
    assert_select "input[name='acquisition_provider[supports_ebooks]'][value='1'][checked='checked']"
    assert_select "input[name='acquisition_provider[supports_audiobooks]'][value='1'][checked='checked']"
  end

  test "show renders provider details without secret" do
    provider = create_provider(api_key: "secret-token")

    get admin_acquisition_provider_url(provider)

    assert_response :success
    assert_select "h1", provider.name
    assert_select "dd", provider.url
    assert_select "dd", "Enabled"
    assert_select "dd", text: /secret-token/, count: 0
  end

  test "create persists provider and assigns next priority" do
    create_provider(name: "Existing Provider", priority: 2)

    assert_difference -> { AcquisitionProvider.count }, 1 do
      post admin_acquisition_providers_url, params: {
        acquisition_provider: provider_params(
          name: "Created Provider",
          url: "http://created-provider.test",
          api_key: "created-secret",
          enabled: "1",
          supports_ebooks: "1",
          supports_audiobooks: "0",
          timeout_seconds: "45"
        )
      }
    end

    assert_redirected_to admin_acquisition_providers_path
    provider = AcquisitionProvider.find_by!(name: "Created Provider")
    assert_equal 3, provider.priority
    assert_equal "created-secret", provider.api_key
    assert provider.enabled?
    assert provider.supports_ebooks?
    assert_not provider.supports_audiobooks?
    assert_equal 45, provider.timeout_seconds
  end

  test "create renders errors for invalid provider" do
    assert_no_difference -> { AcquisitionProvider.count } do
      post admin_acquisition_providers_url, params: {
        acquisition_provider: provider_params(name: "", url: "file:///tmp/provider")
      }
    end

    assert_response :unprocessable_entity
    assert_select "form[action='#{admin_acquisition_providers_path}']"
  end

  test "edit renders form" do
    provider = create_provider

    get edit_admin_acquisition_provider_url(provider)

    assert_response :success
    assert_select "form[action='#{admin_acquisition_provider_path(provider)}']"
  end

  test "update changes provider and preserves blank api key" do
    provider = create_provider(api_key: "existing-secret")

    patch admin_acquisition_provider_url(provider), params: {
      acquisition_provider: provider_params(
        name: "Updated Provider",
        url: "http://updated-provider.test/",
        api_key: "",
        enabled: "0",
        supports_ebooks: "0",
        supports_audiobooks: "1",
        timeout_seconds: "60"
      )
    }

    assert_redirected_to admin_acquisition_providers_path
    provider.reload
    assert_equal "Updated Provider", provider.name
    assert_equal "http://updated-provider.test", provider.url
    assert_equal "existing-secret", provider.api_key
    assert_not provider.enabled?
    assert_not provider.supports_ebooks?
    assert provider.supports_audiobooks?
    assert_equal 60, provider.timeout_seconds
  end

  test "update renders errors for invalid provider" do
    provider = create_provider

    patch admin_acquisition_provider_url(provider), params: {
      acquisition_provider: provider_params(name: "", url: "")
    }

    assert_response :unprocessable_entity
    assert_select "form[action='#{admin_acquisition_provider_path(provider)}']"
  end

  test "destroy removes provider" do
    provider = create_provider

    assert_difference -> { AcquisitionProvider.count }, -1 do
      delete admin_acquisition_provider_url(provider)
    end

    assert_redirected_to admin_acquisition_providers_path
    assert_equal "Acquisition provider was successfully deleted.", flash[:notice]
  end

  test "test action reports successful connection" do
    provider = create_provider

    VCR.turned_off do
      stub_request(:get, "#{provider.url}/health").to_return(status: 204)

      post test_admin_acquisition_provider_url(provider)
    end

    assert_redirected_to admin_acquisition_providers_path
    assert_match /successful/i, flash[:notice]
  end

  test "test action reports failed connection" do
    provider = create_provider

    VCR.turned_off do
      stub_request(:get, "#{provider.url}/health").to_return(status: 500)

      post test_admin_acquisition_provider_url(provider)
    end

    assert_redirected_to admin_acquisition_providers_path
    assert_match /failed/i, flash[:alert]
  end

  private

  def create_provider(**attributes)
    AcquisitionProvider.create!({
      name: "Local Provider",
      url: "http://provider.test",
      enabled: true,
      supports_ebooks: true,
      supports_audiobooks: true,
      priority: 0,
      timeout_seconds: 30
    }.merge(attributes))
  end

  def provider_params(**attributes)
    {
      name: "Local Provider",
      url: "http://provider.test",
      enabled: "1",
      supports_ebooks: "1",
      supports_audiobooks: "1",
      timeout_seconds: "30"
    }.merge(attributes)
  end
end
