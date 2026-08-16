# -*- encoding : utf-8 -*-
#
# The rate limits, editable without a deploy. This is the whole reason
# RequestThrottling reads its numbers from the database rather than using
# Rails 8's rate_limit macro, which fixes them at class-load time.
class Admin::SettingsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!

  def show
    @values = current_values
  end

  # Every key is checked against the permitted list before anything is
  # written, and the whole submission is applied in one transaction: a form
  # that half saved would leave the operator with no way to tell which half.
  def update
    permitted = Setting::INTEGER_DEFAULTS.keys + Setting::STRING_DEFAULTS.keys +
                Setting::ENUM_DEFAULTS.keys
    submitted = params.fetch(:settings, {}).to_unsafe_h.slice(*permitted)

    begin
      Setting.transaction do
        submitted.each do |name, value|
          # Integer(value, 10) rather than to_i for integer keys: "abc".to_i is
          # 0, which here means "disable this limit" -- a typo must not silently
          # switch a limit off. A string or enum key is passed through
          # untouched and validated by the model.
          if Setting::ENUM_DEFAULTS.key?(name)
            Setting.put(name, value)
          elsif Setting::STRING_DEFAULTS.key?(name)
            Setting.put(name, value)
          else
            Setting.put(name, Integer(value, 10))
          end
        end
      end
    rescue ActiveRecord::RecordInvalid, ArgumentError, TypeError
      @values = current_values
      flash.now[:alert] = t("admin.settings.invalid")
      render :show, status: :unprocessable_entity
      return
    end

    # Details, not just the action name: "someone changed the limits" is not an
    # audit trail. The values are the whole content of the change.
    record_admin_action("update_settings", nil,
                        submitted.map { |k, v| "#{k}=#{v}" }.join(", "))
    redirect_to admin_settings_path, :notice => t("admin.settings.saved")
  end

  private

  def current_values
    Setting::INTEGER_DEFAULTS.keys.index_with { |name| Setting.integer(name) }
  end
end
