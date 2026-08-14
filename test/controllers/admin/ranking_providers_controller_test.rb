# frozen_string_literal: true

require "test_helper"

class Admin::RankingProvidersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:two))
  end

  test "index renders providers ordered by priority" do
    second = create_provider(name: "Second Ranker", url: "http://second-ranker.test", priority: 1)
    first = create_provider(name: "First Ranker", url: "http://first-ranker.test", priority: 0)

    get admin_ranking_providers_url

    assert_response :success
    assert_select "h1", "Ranking Providers"
    assert_select "tbody tr:first-child td", text: first.name
    assert_select "tbody tr:last-child td", text: second.name
  end

  test "new renders disabled-by-configuration form" do
    get new_admin_ranking_provider_url

    assert_response :success
    assert_select "form[action='#{admin_ranking_providers_path}']"
    assert_select "input[name='ranking_provider[timeout_seconds]'][value='30']"
  end

  test "create persists encrypted configuration and assigns next priority" do
    create_provider(name: "Existing Ranker", priority: 2)

    assert_difference -> { RankingProvider.count }, 1 do
      post admin_ranking_providers_url, params: {
        ranking_provider: provider_params(
          name: "Created Ranker",
          url: "http://created-ranker.test",
          api_key: "created-secret",
          enabled: "1",
          timeout_seconds: "45"
        )
      }
    end

    assert_redirected_to admin_ranking_providers_path
    provider = RankingProvider.find_by!(name: "Created Ranker")
    assert_equal 3, provider.priority
    assert_equal "created-secret", provider.api_key
    assert provider.enabled?
    assert_equal 45, provider.timeout_seconds
  end

  test "update preserves a blank api key" do
    provider = create_provider(api_key: "existing-secret")

    patch admin_ranking_provider_url(provider), params: {
      ranking_provider: provider_params(
        name: "Updated Ranker",
        url: "http://updated-ranker.test/",
        api_key: "",
        enabled: "0",
        timeout_seconds: "60"
      )
    }

    assert_redirected_to admin_ranking_providers_path
    provider.reload
    assert_equal "Updated Ranker", provider.name
    assert_equal "http://updated-ranker.test", provider.url
    assert_equal "existing-secret", provider.api_key
    assert_not provider.enabled?
    assert_equal 60, provider.timeout_seconds
  end

  test "show does not render secret" do
    provider = create_provider(api_key: "secret-token")

    get admin_ranking_provider_url(provider)

    assert_response :success
    assert_select "h1", provider.name
    assert_select "dd", text: /secret-token/, count: 0
  end

  test "test action reports connection result" do
    provider = create_provider

    VCR.turned_off do
      stub_request(:get, "#{provider.url}/health").to_return(status: 204)
      post test_admin_ranking_provider_url(provider)
    end

    assert_redirected_to admin_ranking_providers_path
    assert_match(/successful/i, flash[:notice])
  end

  test "destroy removes provider" do
    provider = create_provider

    assert_difference -> { RankingProvider.count }, -1 do
      delete admin_ranking_provider_url(provider)
    end

    assert_redirected_to admin_ranking_providers_path
  end

  private

  def create_provider(**attributes)
    RankingProvider.create!({
      name: "Local Ranker",
      url: "http://ranker.test",
      enabled: true,
      priority: 0,
      timeout_seconds: 30
    }.merge(attributes))
  end

  def provider_params(**attributes)
    {
      name: "Local Ranker",
      url: "http://ranker.test",
      enabled: "1",
      timeout_seconds: "30"
    }.merge(attributes)
  end
end
