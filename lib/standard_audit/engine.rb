module StandardAudit
  # A plain (non-isolated) engine: it contributes the AuditLog model, the two
  # jobs and the subscriber wiring, and has no routes, controllers or views.
  # 0.13.0 dropped `isolate_namespace` and the empty `config/routes.rb` it
  # carried. Nothing depended on them: AuditLog sets its own `table_name`, and
  # no host mounted the engine.
  class Engine < ::Rails::Engine
    initializer "standard_audit.subscriber" do
      ActiveSupport.on_load(:active_record) do
        StandardAudit.subscriber.setup!

        # Rails 8.1+ structured event reporter. Feature-detected so the gem
        # still works on older Rails versions that only have AS::Notifications.
        if Rails.respond_to?(:event) && Rails.event.respond_to?(:subscribe)
          Rails.event.subscribe(StandardAudit.event_subscriber)
        end
      end
    end
  end
end
