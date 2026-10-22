require "rails_helper"

RSpec.describe StandardAudit::AuthFailure do
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:request) do
    ActionDispatch::TestRequest.create(
      "PATH_INFO" => "/api/orders",
      "REQUEST_METHOD" => "POST",
      "REMOTE_ADDR" => "203.0.113.7",
      "HTTP_USER_AGENT" => "x" * 2000,
      "action_dispatch.request_id" => "req-123"
    )
  end

  before { StandardAudit.reset_configuration!(replay_baseline: false) }

  after { StandardAudit.reset_configuration!(replay_baseline: false) }

  def last_log
    StandardAudit::AuditLog.order(:created_at).last
  end

  describe ".record" do
    it "writes the allow-listed metadata and the request columns" do
      described_class.record("auth.token_invalid", "AUTH_001", request: request)

      log = last_log
      expect(log.event_type).to eq("auth.token_invalid")
      expect(log.metadata).to eq("error_code" => "AUTH_001", "path" => "/api/orders", "method" => "POST")
      expect(log.request_id).to eq("req-123")
      expect(log.ip_address).to eq("203.0.113.7")
      expect(log.user_agent.length).to eq(described_class::USER_AGENT_LIMIT)
      expect(log.actor_gid).to be_nil
    end

    it "adds exactly the extra keywords the caller passes, as String keys" do
      described_class.record("auth.ip_rejected", "AUTH_004", request: request, station_id: "sz-01", reason: nil)

      expect(last_log.metadata).to eq(
        "error_code" => "AUTH_004", "path" => "/api/orders", "method" => "POST", "station_id" => "sz-01"
      )
    end

    it "records a GlobalID-able actor and drops anything else" do
      described_class.record("auth.token_revoked", "AUTH_003", actor: user, request: request)
      expect(last_log.actor_gid).to eq(user.to_global_id.to_s)

      described_class.record("auth.token_revoked", "AUTH_003", actor: "user-42", request: request)
      expect(last_log.actor_gid).to be_nil
    end

    it "works without a request, from an explicit path" do
      described_class.record("auth.social_denied", "AUTH_009", path: "/auth/callback")

      expect(last_log.metadata).to eq("error_code" => "AUTH_009", "path" => "/auth/callback")
    end

    it "never raises: a failed write returns nil and is reported" do
      StandardAudit.config.before_write = ->(_entry) { raise ActiveRecord::StatementInvalid, "audit table on fire" }
      allow(Rails.error).to receive(:report)
      allow(Rails.logger).to receive(:error)

      expect(described_class.record("auth.token_invalid", "AUTH_001", request: request)).to be_nil
      expect(Rails.error).to have_received(:report).with(an_instance_of(ActiveRecord::StatementInvalid), hash_including(handled: true))
    end

    it "falls back to request.ip when remote_ip detects IP spoofing" do
      env = Rack::MockRequest.env_for("/api/orders",
        "REMOTE_ADDR" => "198.51.100.9", "HTTP_CLIENT_IP" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "10.0.0.2")
      # The real middleware, so remote_ip raises for the real reason.
      ActionDispatch::RemoteIp.new(->(_env) { [200, {}, []] }, true).call(env)
      spoofed = ActionDispatch::Request.new(env)
      expect { spoofed.remote_ip }.to raise_error(ActionDispatch::RemoteIp::IpSpoofAttackError)

      described_class.record("auth.token_invalid", "AUTH_001", request: spoofed)

      expect(last_log.ip_address).to eq("198.51.100.9")
    end

    it "never raises while building the row either" do
      allow(request).to receive(:request_method).and_raise(RuntimeError, "broken request")
      allow(StandardAudit).to receive(:report_write_error)

      expect(described_class.record("auth.token_invalid", "AUTH_001", request: request)).to be_nil
      expect(StandardAudit).to have_received(:report_write_error)
        .with(an_instance_of(RuntimeError), "auth.token_invalid", source: "StandardAudit::AuthFailure")
    end

    it "logs nothing by default" do
      allow(Rails.logger).to receive(:warn)

      described_class.record("auth.token_invalid", "AUTH_001", request: request)

      expect(Rails.logger).not_to have_received(:warn)
    end

    it "emits one structured warn line with config.log_auth_failures" do
      StandardAudit.config.log_auth_failures = true
      allow(Rails.logger).to receive(:warn)

      described_class.record("auth.token_revoked", "AUTH_003", actor: user, request: request, reason: "revoked")

      expect(Rails.logger).to have_received(:warn).once.with(
        hash_including(event: "auth.token_revoked", error_code: "AUTH_003", path: "/api/orders",
          ip: "203.0.113.7", actor: user.to_global_id.to_s, reason: "revoked")
      )
    end

    it "still writes the row when the log line fails" do
      StandardAudit.config.log_auth_failures = true
      allow(Rails.logger).to receive(:warn).and_raise(IOError, "log device closed")
      allow(StandardAudit).to receive(:report_write_error)

      described_class.record("auth.token_invalid", "AUTH_001", request: request)

      expect(last_log.event_type).to eq("auth.token_invalid")
      expect(StandardAudit).to have_received(:report_write_error)
        .with(an_instance_of(IOError), "auth.token_invalid", source: "StandardAudit::AuthFailure log line")
    end

    it "keeps a non-GlobalID actor in the log line, and filters its extras like the row" do
      StandardAudit.config.log_auth_failures = true
      logged = nil
      allow(Rails.logger).to receive(:warn) { |line| logged = line }

      described_class.record("auth.token_invalid", "AUTH_001", actor: "user-42", request: request,
        password: "hunter2", reason: "expired")

      expect(logged).to include(actor: "user-42", reason: "expired")
      expect(logged).not_to have_key(:password)
      expect(last_log.metadata).not_to have_key("password")
    end
  end

  describe StandardAudit::AuthFailure::Controller do
    let(:controller_class) do
      Class.new do
        include StandardAudit::AuthFailure::Controller

        attr_reader :request

        def initialize(request)
          @request = request
        end

        def deny!(actor: nil)
          record_auth_failure("auth.invalid_scope", "AUTH_002", actor: actor, scope: "orders:write")
        end
      end
    end

    it "keeps record_auth_failure private, so it is never an action" do
      expect(controller_class.private_method_defined?(:record_auth_failure)).to be(true)
    end

    it "records against the controller's request" do
      controller_class.new(request).deny!

      expect(last_log.event_type).to eq("auth.invalid_scope")
      expect(last_log.metadata).to eq(
        "error_code" => "AUTH_002", "path" => "/api/orders", "method" => "POST", "scope" => "orders:write"
      )
      expect(last_log.request_id).to eq("req-123")
    end

    it "forwards the actor" do
      controller_class.new(request).deny!(actor: user)

      expect(last_log.actor_gid).to eq(user.to_global_id.to_s)
    end
  end
end
