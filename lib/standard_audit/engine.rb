module StandardAudit
  class Engine < ::Rails::Engine
    isolate_namespace StandardAudit
  end
end
