Rails.application.configure do
  config.enable_reloading = false
  config.consider_all_requests_local = true
  config.action_dispatch.show_exceptions = :none
  config.action_controller.perform_caching = true
  config.cache_store = :memory_store
end
