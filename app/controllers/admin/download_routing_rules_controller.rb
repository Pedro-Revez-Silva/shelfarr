# frozen_string_literal: true

module Admin
  class DownloadRoutingRulesController < BaseController
    before_action :set_download_routing_rule, only: [ :edit, :update, :destroy ]

    def index
      @download_routing_rules = DownloadRoutingRule.includes(:download_client).by_indexer
    end

    def new
      @download_routing_rule = DownloadRoutingRule.new(provider: "prowlarr", download_type: "torrent")
    end

    def create
      @download_routing_rule = DownloadRoutingRule.new(download_routing_rule_params)

      if @download_routing_rule.save
        redirect_to admin_download_routing_rules_path, notice: "Download routing rule was successfully created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @download_routing_rule.update(download_routing_rule_params)
        redirect_to admin_download_routing_rules_path, notice: "Download routing rule was successfully updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @download_routing_rule.destroy
      redirect_to admin_download_routing_rules_path, notice: "Download routing rule was successfully deleted."
    end

    private

    def set_download_routing_rule
      @download_routing_rule = DownloadRoutingRule.find(params[:id])
    end

    def download_routing_rule_params
      params.require(:download_routing_rule).permit(
        :provider, :indexer_name, :download_type, :download_client_id, :enabled
      )
    end
  end
end
