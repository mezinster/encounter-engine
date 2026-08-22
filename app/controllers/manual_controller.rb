# -*- encoding : utf-8 -*-
class ManualController < ApplicationController
  # No authentication guard, deliberately: the manual's first section is
  # "signing up and signing in".
  #
  # The cache key is the file's DIGEST, not a constant and not the locale
  # alone. Rails.cache is :memory_store here, so this costs one render per
  # document per container lifetime; keying on the digest means editing a
  # manual in development invalidates it without a restart, and two locales
  # served by the same fallback file share one entry.
  def show
    document = Manual::Source.for(I18n.locale)

    @locale_used = document.locale_used
    @manual_html = Rails.cache.fetch(["manual", document.locale_used, document.digest]) do
      Manual::Renderer.call(document.markdown)
    end
  end
end
