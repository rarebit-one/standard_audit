module StandardAudit
  class Engine < ::Rails::Engine
    isolate_namespace StandardAudit

    initializer "standard_audit.subscriber" do
      ActiveSupport.on_load(:active_record) do
        StandardAudit.subscriber.setup!
      end
    end
  end
end
