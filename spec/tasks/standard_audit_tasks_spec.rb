require "rails_helper"
require "rake"

RSpec.describe "standard_audit rake tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("standard_audit:cleanup")
  end

  let(:user) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:other_user) { User.create!(name: "Bob", email: "bob@example.com") }

  before do
    StandardAudit.instance_variable_set(:@configuration, nil)
    StandardAudit.configure { |config| config.retention_days = nil }
  end

  after do
    StandardAudit.instance_variable_set(:@configuration, nil)
  end

  def run_task(name, *args)
    task = Rake::Task[name]
    task.reenable
    task.invoke(*args)
  end

  def create_log(occurred_at: Time.current, actor: nil, **attrs)
    log = StandardAudit::AuditLog.new({ event_type: "test.event", occurred_at: occurred_at }.merge(attrs))
    log.actor = actor if actor
    log.save!
    log
  end

  shared_examples "a retention-window task" do |task_name|
    it "aborts when neither days nor retention_days is given (nil = keep forever)" do
      create_log(occurred_at: 400.days.ago)

      expect {
        expect { run_task("standard_audit:#{task_name}") }.to raise_error(SystemExit)
      }.to output(/no retention window.*keep forever/m).to_stderr
    end

    ["0", "-5", "abc", "1.5"].each do |bad|
      it "aborts on days=#{bad.inspect}" do
        create_log(occurred_at: 1.day.ago)

        expect {
          expect { run_task("standard_audit:#{task_name}", bad) }.to raise_error(SystemExit)
        }.to output(/days must be a positive integer/).to_stderr
      end
    end

    it "aborts when retention_days is configured to a non-positive value" do
      StandardAudit.config.retention_days = 0

      expect {
        expect { run_task("standard_audit:#{task_name}") }.to raise_error(SystemExit)
      }.to output(/days must be a positive integer/).to_stderr
    end
  end

  describe "standard_audit:verify" do
    around do |example|
      saved = ENV.values_at("FAIL_ON_LEGACY_UNVERIFIABLE", "KEY_ORDER_SEARCH_LIMIT")
      example.run
    ensure
      ENV["FAIL_ON_LEGACY_UNVERIFIABLE"], ENV["KEY_ORDER_SEARCH_LIMIT"] = saved
    end

    # A pre-cutover row whose metadata keys were reordered by the store, with
    # the search disabled so the original order stays out of reach.
    def lost_order_row
      now = (StandardAudit.config.canonical_checksum_since - 1.day).floor(6)
      id = SecureRandom.uuid_v7
      attrs = { "id" => id, "event_type" => "legacy", "metadata" => { probe: 1, run: 2 }, "occurred_at" => now }
      digest = StandardAudit::Checksum.legacy_digest(attrs, fields: StandardAudit::AuditLog::CHECKSUM_FIELDS)
      StandardAudit::AuditLog.insert_all!([{ id: id, event_type: "legacy", metadata: { run: 2, probe: 1 },
        occurred_at: now, checksum: digest, created_at: now, updated_at: now }])
      ENV["KEY_ORDER_SEARCH_LIMIT"] = "0"
    end

    it "passes on a clean chain" do
      create_log

      expect { run_task("standard_audit:verify") }.to output(/Chain valid: true/).to_stdout
    end

    it "reports unverifiable legacy rows without failing" do
      lost_order_row

      expect { run_task("standard_audit:verify") }
        .to output(/Chain valid: true.*unverifiable \(metadata key order lost\): 1/m).to_stdout
    end

    it "fails on them with FAIL_ON_LEGACY_UNVERIFIABLE=1, naming the reason" do
      lost_order_row
      ENV["FAIL_ON_LEGACY_UNVERIFIABLE"] = "1"

      expect {
        expect { run_task("standard_audit:verify") }.to raise_error(SystemExit)
      }.to output(/legacy_key_order_unverifiable: 1/).to_stdout.and output(/Chain verification failed/).to_stderr
    end
  end

  describe "standard_audit:cleanup" do
    it_behaves_like "a retention-window task", "cleanup"

    it "deletes logs older than the days argument" do
      old = create_log(occurred_at: 40.days.ago)
      recent = create_log(occurred_at: 10.days.ago)

      expect { run_task("standard_audit:cleanup", "30") }.to output(/Deleted 1 audit logs older than 30 days/).to_stdout

      expect(StandardAudit::AuditLog.exists?(old.id)).to be(false)
      expect(StandardAudit::AuditLog.exists?(recent.id)).to be(true)
    end

    it "falls back to config.retention_days" do
      StandardAudit.config.retention_days = 30
      create_log(occurred_at: 40.days.ago)
      create_log(occurred_at: 10.days.ago)

      expect { run_task("standard_audit:cleanup") }.to output(/Deleted 1 audit logs older than 30 days/).to_stdout
      expect(StandardAudit::AuditLog.count).to eq(1)
    end

    it "prefers the days argument over config.retention_days" do
      StandardAudit.config.retention_days = 5
      create_log(occurred_at: 10.days.ago)

      expect { run_task("standard_audit:cleanup", "30") }.to output(/Deleted 0 audit logs older than 30 days/).to_stdout
      expect(StandardAudit::AuditLog.count).to eq(1)
    end

    it "does not delete anything when days is non-numeric" do
      create_log(occurred_at: 1.minute.ago)

      expect {
        expect { run_task("standard_audit:cleanup", "abc") }.to raise_error(SystemExit)
      }.to output.to_stderr
      expect(StandardAudit::AuditLog.count).to eq(1)
    end
  end

  describe "standard_audit:archive" do
    let(:output_path) { Rails.root.join("tmp", "archive_spec_#{SecureRandom.hex(4)}.json").to_s }

    before { FileUtils.mkdir_p(File.dirname(output_path)) }
    after { FileUtils.rm_f(output_path) }

    it_behaves_like "a retention-window task", "archive"

    it "archives logs older than the days argument" do
      old = create_log(occurred_at: 40.days.ago)
      create_log(occurred_at: 10.days.ago)

      expect { run_task("standard_audit:archive", "30", output_path) }.to output(/Archived 1 logs/).to_stdout

      lines = File.readlines(output_path)
      expect(lines.size).to eq(1)
      expect(JSON.parse(lines.first)["id"]).to eq(old.id)
    end

    it "falls back to config.retention_days instead of a hard-coded 90" do
      StandardAudit.config.retention_days = 30
      create_log(occurred_at: 40.days.ago)

      expect { run_task("standard_audit:archive", nil, output_path) }.to output(/Archived 1 logs/).to_stdout
    end
  end

  describe "standard_audit:anonymize_actor" do
    it "anonymizes by GlobalID string" do
      log = create_log(actor: user, ip_address: "10.0.0.1")
      untouched = create_log(actor: other_user, ip_address: "10.0.0.2")
      gid = user.to_global_id.to_s

      expect { run_task("standard_audit:anonymize_actor", gid) }.to output(/Anonymized 1 audit logs for #{Regexp.escape(gid)}/).to_stdout

      expect(log.reload.actor_gid).to eq("[anonymized]")
      expect(log.ip_address).to be_nil
      expect(untouched.reload.ip_address).to eq("10.0.0.2")
    end

    it "works after the user row has been deleted" do
      log = create_log(actor: user)
      gid = user.to_global_id.to_s
      user.destroy!

      expect { run_task("standard_audit:anonymize_actor", gid) }.to output(/Anonymized 1/).to_stdout
      expect(log.reload.actor_gid).to eq("[anonymized]")
    end

    it "raises on an invalid GlobalID string" do
      expect { run_task("standard_audit:anonymize_actor", "not-a-gid") }.to raise_error(ArgumentError, /GlobalID/)
    end
  end

  describe "standard_audit:export_actor" do
    let(:output_path) { Rails.root.join("tmp", "export_spec_#{SecureRandom.hex(4)}.json").to_s }

    before { FileUtils.mkdir_p(File.dirname(output_path)) }
    after { FileUtils.rm_f(output_path) }

    it "exports by GlobalID string" do
      create_log(actor: user, event_type: "user.login")
      create_log(actor: other_user)
      gid = user.to_global_id.to_s

      expect { run_task("standard_audit:export_actor", gid, output_path) }.to output(/Exported 1 audit logs/).to_stdout

      data = JSON.parse(File.read(output_path))
      expect(data["subject"]).to eq(gid)
      expect(data["records"].map { |r| r["event_type"] }).to eq(["user.login"])
    end

    it "raises on an invalid GlobalID string" do
      expect { run_task("standard_audit:export_actor", "not-a-gid", output_path) }.to raise_error(ArgumentError, /GlobalID/)
    end
  end
end
