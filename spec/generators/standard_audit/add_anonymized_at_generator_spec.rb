require "rails_helper"
require "rails/generators"
require "generators/standard_audit/add_anonymized_at/add_anonymized_at_generator"

RSpec.describe StandardAudit::Generators::AddAnonymizedAtGenerator do
  # The migration runs real DDL against the dummy database; a wrapping
  # transaction would hide what rollback actually does to the schema.
  self.use_transactional_tests = false

  let(:destination_root) { File.expand_path("../../../tmp/add_anonymized_at_test", __dir__) }
  let(:connection) { ActiveRecord::Base.connection }

  before do
    FileUtils.rm_rf(destination_root)
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
  end

  after do
    FileUtils.rm_rf(destination_root)
    # Leave the dummy schema as every other spec expects it.
    connection.add_column(:audit_logs, :anonymized_at, :datetime) unless anonymized_at_column?
    StandardAudit::AuditLog.reset_column_information
  end

  def migration_path
    Dir.chdir(destination_root) do
      generator = described_class.new([], {})
      generator.destination_root = destination_root
      generator.invoke_all
    end

    Dir.glob(File.join(destination_root, "db/migrate/*_add_anonymized_at_to_audit_logs.rb")).first
  end

  def migration
    namespace = Module.new
    namespace.module_eval(File.read(migration_path), migration_path)
    namespace::AddAnonymizedAtToAuditLogs.new
  end

  def run(direction)
    ActiveRecord::Migration.suppress_messages { migration.migrate(direction) }
    StandardAudit::AuditLog.reset_column_information
  end

  def anonymized_at_column?
    connection.column_exists?(:audit_logs, :anonymized_at)
  end

  it "adds a nullable datetime column without an early return that would short-circuit rollback" do
    content = File.read(migration_path)

    expect(content).to include("add_column :audit_logs, :anonymized_at, :datetime, if_not_exists: true")
    expect(content).to include("remove_column :audit_logs, :anonymized_at, if_exists: true")
    code = content.lines.grep_v(/\A\s*#/).join
    expect(code).not_to match(/return\s+if\s+column_exists\?/)
  end

  it "migrates up, down and up again" do
    # The dummy schema already has the column (0.12 install shape); start from
    # the pre-0.12 shape the generator exists for.
    connection.remove_column(:audit_logs, :anonymized_at)
    StandardAudit::AuditLog.reset_column_information

    run(:up)
    expect(anonymized_at_column?).to be(true)
    column = connection.columns(:audit_logs).find { |c| c.name == "anonymized_at" }
    expect(column.type).to eq(:datetime)
    expect(column.null).to be(true)

    run(:down)
    expect(anonymized_at_column?).to be(false)

    run(:up)
    expect(anonymized_at_column?).to be(true)
  end

  it "is a no-op when the column already exists and when rolling back without it" do
    expect(anonymized_at_column?).to be(true)
    expect { run(:up) }.not_to raise_error
    expect(anonymized_at_column?).to be(true)

    run(:down)
    expect { run(:down) }.not_to raise_error
    expect(anonymized_at_column?).to be(false)
  end
end
