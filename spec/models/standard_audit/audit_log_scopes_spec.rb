require "rails_helper"

RSpec.describe StandardAudit::AuditLog, "scopes", type: :model do
  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:other_user) { User.create!(name: "Bob", email: "bob@example.com") }
  let(:org) { Organisation.create!(name: "Acme") }
  let(:order) { Order.create!(user: user, organisation: org, total: 42.0) }

  def create_log(attrs = {})
    log = StandardAudit::AuditLog.new({
      event_type: "test.event",
      occurred_at: Time.current
    }.merge(attrs.except(:actor, :target, :scope)))
    log.actor = attrs[:actor] if attrs.key?(:actor)
    log.target = attrs[:target] if attrs.key?(:target)
    log.scope = attrs[:scope] if attrs.key?(:scope)
    log.save!
    log
  end

  describe ".for_actor" do
    it "finds logs by actor's GlobalID" do
      log1 = create_log(actor: user)
      _log2 = create_log(actor: other_user)

      expect(described_class.for_actor(user)).to contain_exactly(log1)
    end
  end

  describe ".by_actor_type" do
    it "filters by class name as a string" do
      log1 = create_log(actor: user)
      _log2 = create_log(actor: nil, target: order)

      expect(described_class.by_actor_type("User")).to contain_exactly(log1)
    end

    it "filters by class name when given a Class" do
      log1 = create_log(actor: user)
      _log2 = create_log

      expect(described_class.by_actor_type(User)).to contain_exactly(log1)
    end
  end

  describe ".for_target" do
    it "finds logs by target's GlobalID" do
      log1 = create_log(target: order)
      _log2 = create_log(target: user)

      expect(described_class.for_target(order)).to contain_exactly(log1)
    end
  end

  describe ".by_target_type" do
    it "filters by class name" do
      log1 = create_log(target: order)
      _log2 = create_log(target: user)

      expect(described_class.by_target_type("Order")).to contain_exactly(log1)
    end
  end

  describe ".for_scope" do
    it "finds logs by scope's GlobalID" do
      log1 = create_log(scope: org)
      _log2 = create_log

      expect(described_class.for_scope(org)).to contain_exactly(log1)
    end
  end

  describe ".by_scope_type" do
    it "filters by class name" do
      log1 = create_log(scope: org)
      _log2 = create_log

      expect(described_class.by_scope_type("Organisation")).to contain_exactly(log1)
    end
  end

  describe ".by_event_type" do
    it "filters exact match" do
      log1 = create_log(event_type: "user.created")
      _log2 = create_log(event_type: "user.updated")

      expect(described_class.by_event_type("user.created")).to contain_exactly(log1)
    end
  end

  describe ".matching_event" do
    it "filters with LIKE pattern" do
      log1 = create_log(event_type: "user.created")
      log2 = create_log(event_type: "user.updated")
      _log3 = create_log(event_type: "order.created")

      expect(described_class.matching_event("user.%")).to contain_exactly(log1, log2)
    end
  end

  describe ".between" do
    it "filters by date range" do
      log1 = create_log(occurred_at: 2.days.ago)
      _log2 = create_log(occurred_at: 5.days.ago)
      log3 = create_log(occurred_at: 1.day.ago)

      expect(described_class.between(3.days.ago, Time.current)).to contain_exactly(log1, log3)
    end
  end

  describe ".since" do
    it "filters logs since given time" do
      log1 = create_log(occurred_at: 1.hour.ago)
      _log2 = create_log(occurred_at: 3.days.ago)

      expect(described_class.since(1.day.ago)).to contain_exactly(log1)
    end
  end

  describe ".before" do
    it "filters logs before given time" do
      _log1 = create_log(occurred_at: 1.hour.ago)
      log2 = create_log(occurred_at: 3.days.ago)

      expect(described_class.before(1.day.ago)).to contain_exactly(log2)
    end
  end

  describe ".today" do
    it "returns only today's logs" do
      log1 = create_log(occurred_at: Time.current)
      _log2 = create_log(occurred_at: 2.days.ago)

      expect(described_class.today).to contain_exactly(log1)
    end
  end

  describe ".yesterday" do
    it "returns only yesterday's logs" do
      _log1 = create_log(occurred_at: Time.current)
      log2 = create_log(occurred_at: 1.day.ago.middle_of_day)

      expect(described_class.yesterday).to contain_exactly(log2)
    end
  end

  describe ".this_week" do
    it "returns logs from the current week" do
      log1 = create_log(occurred_at: Time.current)
      _log2 = create_log(occurred_at: 2.weeks.ago)

      expect(described_class.this_week).to include(log1)
      expect(described_class.this_week).not_to include(_log2)
    end
  end

  describe ".this_month" do
    it "returns logs from the current month" do
      log1 = create_log(occurred_at: Time.current)
      _log2 = create_log(occurred_at: 2.months.ago)

      expect(described_class.this_month).to include(log1)
      expect(described_class.this_month).not_to include(_log2)
    end
  end

  describe ".last_n_days" do
    it "returns logs from the last N days" do
      log1 = create_log(occurred_at: 1.day.ago)
      log2 = create_log(occurred_at: 3.days.ago)
      _log3 = create_log(occurred_at: 10.days.ago)

      expect(described_class.last_n_days(5)).to contain_exactly(log1, log2)
    end
  end

  describe ".for_request" do
    it "filters by request_id" do
      log1 = create_log(request_id: "req-123")
      _log2 = create_log(request_id: "req-456")

      expect(described_class.for_request("req-123")).to contain_exactly(log1)
    end
  end

  describe ".from_ip" do
    it "filters by ip_address" do
      log1 = create_log(ip_address: "192.168.1.1")
      _log2 = create_log(ip_address: "10.0.0.1")

      expect(described_class.from_ip("192.168.1.1")).to contain_exactly(log1)
    end
  end

  describe ".for_session" do
    it "filters by session_id" do
      log1 = create_log(session_id: "sess-abc")
      _log2 = create_log(session_id: "sess-xyz")

      expect(described_class.for_session("sess-abc")).to contain_exactly(log1)
    end
  end

  describe ".chronological" do
    it "orders by occurred_at ascending" do
      log1 = create_log(occurred_at: 2.days.ago)
      log2 = create_log(occurred_at: 1.day.ago)
      log3 = create_log(occurred_at: 3.days.ago)

      expect(described_class.chronological.to_a).to eq([log3, log1, log2])
    end
  end

  describe ".reverse_chronological" do
    it "orders by occurred_at descending" do
      log1 = create_log(occurred_at: 2.days.ago)
      log2 = create_log(occurred_at: 1.day.ago)
      log3 = create_log(occurred_at: 3.days.ago)

      expect(described_class.reverse_chronological.to_a).to eq([log2, log1, log3])
    end
  end

  describe ".recent" do
    it "returns last N in reverse chronological order" do
      log1 = create_log(occurred_at: 3.days.ago)
      log2 = create_log(occurred_at: 2.days.ago)
      log3 = create_log(occurred_at: 1.day.ago)

      expect(described_class.recent(2)).to eq([log3, log2])
    end

    it "defaults to 10" do
      12.times { |i| create_log(occurred_at: i.hours.ago) }

      expect(described_class.recent.count).to eq(10)
    end
  end
end
