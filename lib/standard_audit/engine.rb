module StandardAudit
  class Engine < ::Rails::Engine
    isolate_namespace StandardAudit

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
