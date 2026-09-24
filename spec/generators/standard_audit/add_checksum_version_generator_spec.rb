require "rails_helper"
require "rails/generators"
require "generators/standard_audit/add_checksum_version/add_checksum_version_generator"

RSpec.describe StandardAudit::Generators::AddChecksumVersionGenerator do
  # The migration runs real DDL against the dummy database; a wrapping
  # transaction would hide what rollback actually does to the schema.
  self.use_transactional_tests = false

  let(:destination_root) { File.expand_path("../../../tmp/add_checksum_version_test", __dir__) }
  let(:connection) { ActiveRecord::Base.connection }

  before do
    FileUtils.rm_rf(destination_root)
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
  end

  after do
    FileUtils.rm_rf(destination_root)
    # Leave the dummy schema as every other spec expects it.
    connection.add_column(:audit_logs, :checksum_version, :integer, limit: 2) unless version_column?
    StandardAudit::AuditLog.reset_column_information
  end

  def migration_path
    Dir.chdir(destination_root) do
      generator = described_class.new([], {})
      generator.destination_root = destination_root
      generator.invoke_all
    end

    Dir.glob(File.join(destination_root, "db/migrate/*_add_checksum_version_to_audit_logs.rb")).first
  end

  def migration
    namespace = Module.new
    namespace.module_eval(File.read(migration_path), migration_path)
    namespace::AddChecksumVersionToAuditLogs.new
  end

  def run(direction, instance = migration)
    ActiveRecord::Migration.suppress_messages { instance.migrate(direction) }
    StandardAudit::AuditLog.reset_column_information
  end

  def version_column?
    connection.column_exists?(:audit_logs, :checksum_version)
  end

  it "sorts after the host's latest migration when that one is future-dated" do
    travel_to(Time.utc(2026, 9, 25, 12, 0, 0)) do
      File.write(File.join(destination_root, "db/migrate/20261231235959_future_dated.rb"), "")
      expect(File.basename(migration_path)).to start_with("20270101000000_")
    end
  end

  it "adds a nullable column with no default and does not backfill existing rows" do
    content = File.read(migration_path)
    code = content.lines.grep_v(/\A\s*#/).join

    expect(code).to include("add_column :audit_logs, :checksum_version, :integer, limit: 2, if_not_exists: true")
    expect(code).to include("remove_column :audit_logs, :checksum_version, if_exists: true")
    expect(code).not_to match(/default:|update_all|execute/)
  end

  it "migrates up, down and up again, leaving existing rows unmarked" do
    connection.remove_column(:audit_logs, :checksum_version)
    StandardAudit::AuditLog.reset_column_information
    legacy = StandardAudit::AuditLog.create!(event_type: "before.migration", occurred_at: Time.current)

    run(:up)
    expect(version_column?).to be(true)
    column = connection.columns(:audit_logs).find { |c| c.name == "checksum_version" }
    expect(column.type).to eq(:integer)
    expect(column.null).to be(true)
    expect(legacy.reload.checksum_version).to be_nil

    run(:down)
    expect(version_column?).to be(false)

    run(:up)
    expect(version_column?).to be(true)
  ensure
    StandardAudit::AuditLog.delete_all
  end

  it "is a no-op when the column already exists and when rolling back without it" do
    expect(version_column?).to be(true)
    expect { run(:up) }.not_to raise_error

    run(:down)
    expect { run(:down) }.not_to raise_error
    expect(version_column?).to be(false)
  end

  it "wraps its DDL in safety_assured when StrongMigrations is loaded" do
    instance = migration
    assured = 0
    instance.define_singleton_method(:safety_assured) do |&block|
      assured += 1
      block.call
    end

    run(:down, instance)
    expect(assured).to eq(1)
  end
end
