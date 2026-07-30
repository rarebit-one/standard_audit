require "rails_helper"

RSpec.describe StandardAudit::ReferencePreloading do
  # Counts SELECTs issued inside the block. Schema/transaction chatter is
  # filtered out so the assertions pin the number of *reference* lookups.
  def count_queries
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_n, _s, _f, _i, payload|
      next if payload[:cached]
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])
      next unless payload[:sql].to_s.match?(/\ASELECT/i)

      queries << payload[:sql]
    end

    yield

    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def build_log(event_type: "test.event", **attrs)
    StandardAudit::AuditLog.create!(event_type: event_type, occurred_at: Time.current, **attrs)
  end

  let(:organisation) { Organisation.create!(name: "Acme") }

  describe ".preload_references" do
    it "resolves actors for a page of logs in one query per type" do
      users = 3.times.map { |i| User.create!(name: "U#{i}", email: "u#{i}@example.com") }
      users.each { |user| build_log.tap { |log| log.update_columns(actor_gid: user.to_global_id.to_s, actor_type: "User") } }

      logs = StandardAudit::AuditLog.all.to_a

      unpreloaded = count_queries { logs.each(&:actor) }
      expect(unpreloaded.size).to eq(3)

      logs = StandardAudit::AuditLog.all.to_a
      preloaded = count_queries do
        StandardAudit::AuditLog.preload_references(logs, refs: %i[actor])
        logs.each(&:actor)
      end
      expect(preloaded.size).to eq(1)
      expect(logs.map(&:actor)).to match_array(users)
    end

    it "resolves actor and target together, one query per distinct type" do
      user = User.create!(name: "U", email: "u@example.com")
      order = Order.create!(user: user, organisation: organisation, total: 10)
      3.times do
        log = build_log
        log.update_columns(
          actor_gid: user.to_global_id.to_s, actor_type: "User",
          target_gid: order.to_global_id.to_s, target_type: "Order"
        )
      end

      logs = StandardAudit::AuditLog.all.to_a
      queries = count_queries do
        StandardAudit::AuditLog.preload_references(logs)
        logs.each { |log| [log.actor, log.target] }
      end

      expect(queries.size).to eq(2)
      expect(logs.map(&:actor).uniq).to eq([user])
      expect(logs.map(&:target).uniq).to eq([order])
    end

    it "defaults to actor and target, leaving scope unpreloaded" do
      user = User.create!(name: "U", email: "u@example.com")
      order = Order.create!(user: user, total: 1)
      log = build_log
      log.update_columns(
        actor_gid: user.to_global_id.to_s, actor_type: "User",
        target_gid: order.to_global_id.to_s, target_type: "Order",
        scope_gid: organisation.to_global_id.to_s, scope_type: "Organisation"
      )

      logs = StandardAudit::AuditLog.all.to_a
      StandardAudit::AuditLog.preload_references(logs)

      expect(logs.first.actor_preloaded?).to be(true)
      expect(logs.first.target_preloaded?).to be(true)
      expect(logs.first.scope_preloaded?).to be(false)
    end

    it "preloads scope when asked" do
      log = build_log
      log.update_columns(scope_gid: organisation.to_global_id.to_s, scope_type: "Organisation")

      logs = StandardAudit::AuditLog.all.to_a
      StandardAudit::AuditLog.preload_references(logs, refs: %i[scope])

      queries = count_queries { expect(logs.first.scope).to eq(organisation) }
      expect(queries).to be_empty
    end

    it "memoizes nil for a deleted record so the reader never queries again" do
      user = User.create!(name: "Gone", email: "gone@example.com")
      log = build_log
      log.update_columns(actor_gid: user.to_global_id.to_s, actor_type: "User")
      user.destroy!

      logs = StandardAudit::AuditLog.all.to_a
      StandardAudit::AuditLog.preload_references(logs, refs: %i[actor])

      expect(logs.first.actor_preloaded?).to be(true)

      queries = count_queries { expect(logs.first.actor).to be_nil }
      expect(queries).to be_empty
    end

    it "returns an empty array untouched and issues no queries" do
      expect(count_queries { expect(StandardAudit::AuditLog.preload_references([])).to eq([]) }).to be_empty
    end

    it "accepts a relation as well as an array" do
      user = User.create!(name: "U", email: "u@example.com")
      log = build_log
      log.update_columns(actor_gid: user.to_global_id.to_s, actor_type: "User")

      logs = StandardAudit::AuditLog.preload_references(StandardAudit::AuditLog.all, refs: %i[actor])

      expect(logs).to be_a(Array)
      expect(logs.first.actor).to eq(user)
    end

    it "raises on an unknown reference name" do
      expect { StandardAudit::AuditLog.preload_references([build_log], refs: %i[owner]) }
        .to raise_error(ArgumentError, /unknown audit reference :owner/)
    end

    it "skips logs with a blank type or gid" do
      build_log
      logs = StandardAudit::AuditLog.all.to_a

      queries = count_queries { StandardAudit::AuditLog.preload_references(logs) }
      expect(queries).to be_empty
      expect(logs.first.actor).to be_nil
    end

    it "leaves a blank *_type with a populated *_gid resolvable by the per-row reader" do
      # Historical / partially-backfilled rows can carry a gid without a type.
      # The gid alone is enough for GlobalID::Locator, so preloading must not
      # turn that into a permanent nil.
      user = User.create!(name: "U", email: "u@example.com")
      log = build_log
      log.update_columns(actor_gid: user.to_global_id.to_s, actor_type: nil)

      logs = StandardAudit::AuditLog.all.to_a
      StandardAudit::AuditLog.preload_references(logs, refs: %i[actor])

      expect(logs.first.actor_preloaded?).to be(false)
      expect(logs.first.actor).to eq(user)
    end

    describe "only:" do
      it "resolves whitelisted types and memoizes nil for the rest" do
        user = User.create!(name: "U", email: "u@example.com")
        order = Order.create!(user: user, total: 5)

        allowed = build_log
        allowed.update_columns(target_gid: user.to_global_id.to_s, target_type: "User")
        denied = build_log
        denied.update_columns(target_gid: order.to_global_id.to_s, target_type: "Order")

        logs = StandardAudit::AuditLog.order(:created_at, :id).to_a
        StandardAudit::AuditLog.preload_references(logs, refs: %i[target], only: [User])

        expect(logs.map(&:target_preloaded?)).to eq([true, true])
        queries = count_queries do
          expect(logs.map(&:target)).to eq([user, nil])
        end
        expect(queries).to be_empty
      end

      it "never constantizes a stored type string that is not whitelisted" do
        log = build_log
        log.update_columns(actor_gid: "gid://dummy/NoSuchClassAnywhere/1", actor_type: "NoSuchClassAnywhere")

        logs = StandardAudit::AuditLog.all.to_a

        expect { StandardAudit::AuditLog.preload_references(logs, refs: %i[actor], only: [User]) }
          .not_to raise_error
        expect(logs.first.actor).to be_nil
      end

      it "leaves rows unmemoized when an un-whitelisted run hits a dead type string" do
        # Without `only:`, the gem must constantize whatever is stored. A
        # historical class name that no longer exists is logged and the rows are
        # left alone so the per-row reader behaves exactly as before.
        log = build_log
        log.update_columns(actor_gid: "gid://dummy/NoSuchClassAnywhere/1", actor_type: "NoSuchClassAnywhere")

        logs = StandardAudit::AuditLog.all.to_a
        allow(Rails.logger).to receive(:warn)

        expect { StandardAudit::AuditLog.preload_references(logs, refs: %i[actor]) }.not_to raise_error
        expect(Rails.logger).to have_received(:warn).with(/Could not preload actor/)
        expect(logs.first.actor_preloaded?).to be(false)
      end
    end

    describe "includes:" do
      it "eager-loads a per-type association so a nested read does not query" do
        user = User.create!(name: "U", email: "u@example.com")
        3.times do
          order = Order.create!(user: user, organisation: organisation, total: 1)
          build_log.update_columns(target_gid: order.to_global_id.to_s, target_type: "Order")
        end

        logs = StandardAudit::AuditLog.all.to_a
        queries = count_queries do
          StandardAudit::AuditLog.preload_references(
            logs, refs: %i[target], includes: { "Order" => [:user] }
          )
          logs.each { |log| log.target.user.name }
        end

        # One for the orders, one for the eager-loaded users.
        expect(queries.size).to eq(2)
      end

      it "accepts a Class key as well as a String key" do
        order = Order.create!(user: User.create!(name: "U", email: "u@example.com"), total: 1)
        build_log.update_columns(target_gid: order.to_global_id.to_s, target_type: "Order")

        logs = StandardAudit::AuditLog.all.to_a
        queries = count_queries do
          StandardAudit::AuditLog.preload_references(logs, refs: %i[target], includes: { Order => [:user] })
          logs.each { |log| log.target.user.name }
        end

        expect(queries.size).to eq(2)
      end

      it "applies a symbol-keyed Hash uniformly rather than treating it as a per-type map" do
        order = Order.create!(user: User.create!(name: "U", email: "u@example.com"), total: 1)
        build_log.update_columns(target_gid: order.to_global_id.to_s, target_type: "Order")

        logs = StandardAudit::AuditLog.all.to_a
        StandardAudit::AuditLog.preload_references(logs, refs: %i[target], includes: :user)
        expect(logs.first.target).to eq(order)

        logs = StandardAudit::AuditLog.all.to_a
        StandardAudit::AuditLog.preload_references(logs, refs: %i[target], includes: { user: [] })
        expect(logs.first.target).to eq(order)
      end
    end
  end

  describe "the preload memo" do
    it "distinguishes 'preloaded to nil' from 'not preloaded'" do
      user = User.create!(name: "U", email: "u@example.com")
      log = build_log
      log.update_columns(actor_gid: user.to_global_id.to_s, actor_type: "User")
      log = StandardAudit::AuditLog.find(log.id)

      expect(log.actor_preloaded?).to be(false)
      expect(count_queries { log.actor }.size).to eq(1)

      log.preloaded_actor = nil
      expect(log.actor_preloaded?).to be(true)
      expect(count_queries { expect(log.actor).to be_nil }).to be_empty
    end

    it "is populated by the writers, which already hold the record" do
      user = User.create!(name: "U", email: "u@example.com")
      log = StandardAudit::AuditLog.new(event_type: "x", occurred_at: Time.current)
      log.actor = user

      expect(log.actor_preloaded?).to be(true)
      expect(count_queries { expect(log.actor).to eq(user) }).to be_empty
    end

    it "records a nil assignment as a resolved nil" do
      log = StandardAudit::AuditLog.new(event_type: "x", occurred_at: Time.current)
      log.actor = nil

      expect(log.actor_preloaded?).to be(true)
      expect(log.actor).to be_nil
      expect(log.actor_gid).to be_nil
      expect(log.actor_type).to be_nil
    end

    it "survives a save and is cleared by reload" do
      user = User.create!(name: "U", email: "u@example.com")
      log = StandardAudit::AuditLog.new(event_type: "x", occurred_at: Time.current)
      log.actor = user
      log.save!

      expect(log.actor_preloaded?).to be(true)

      log.reload

      expect(log.actor_preloaded?).to be(false)
      expect(count_queries { expect(log.actor).to eq(user) }.size).to eq(1)
    end
  end

  describe "#<ref>_model_id" do
    it "takes the trailing gid segment for actor, target and scope" do
      log = build_log
      log.update_columns(
        actor_gid: "gid://some-other-app/Account/abc-123", actor_type: "Account",
        target_gid: "gid://dummy/Order/42", target_type: "Order",
        scope_gid: nil
      )
      log.reload

      expect(log.actor_model_id).to eq("abc-123")
      expect(log.target_model_id).to eq("42")
      expect(log.scope_model_id).to be_nil
    end

    it "is app-name agnostic where GlobalID.parse(...).model_id is not usable" do
      # The stored gid's app segment differs from GlobalID.app. The trailing
      # segment still yields the id; a locator-based extraction would be
      # resolving against the wrong app.
      expect(GlobalID.app).not_to eq("some-other-app")
      expect(StandardAudit::AuditLog.reference_model_id("gid://some-other-app/Account/abc-123")).to eq("abc-123")
    end

    it "returns nil for a blank gid" do
      expect(StandardAudit::AuditLog.reference_model_id(nil)).to be_nil
      expect(StandardAudit::AuditLog.reference_model_id("")).to be_nil
    end

    it "unescapes the id segment, as URI::GID escapes it on the way in" do
      expect(StandardAudit::AuditLog.reference_model_id("gid://app/Account/a%2Fb")).to eq("a/b")
      expect(StandardAudit::AuditLog.reference_model_id("gid://app/Account/a%20b")).to eq("a b")
    end

    it "ignores gid params" do
      expect(StandardAudit::AuditLog.reference_model_id("gid://app/Account/7?db=shard1")).to eq("7")
    end

    it "returns an Array for a composite primary key, like GlobalID#model_id" do
      expect(StandardAudit::AuditLog.reference_model_id("gid://app/Seat/1/2")).to eq(%w[1 2])
    end

    it "agrees with GlobalID#model_id for a gid this app can parse" do
      user = User.create!(name: "U", email: "u@example.com")
      gid = user.to_global_id.to_s

      expect(StandardAudit::AuditLog.reference_model_id(gid)).to eq(GlobalID.parse(gid).model_id)
    end
  end

  describe "batched writes" do
    it "never instantiates a model, so the memo is a no-op on that path" do
      user = User.create!(name: "U", email: "u@example.com")

      StandardAudit.batch do
        StandardAudit.record("batched.event", actor: user)
      end

      row = StandardAudit::AuditLog.last
      expect(row.actor_gid).to eq(user.to_global_id.to_s)
      expect(row.actor_preloaded?).to be(false)
    end
  end
end
