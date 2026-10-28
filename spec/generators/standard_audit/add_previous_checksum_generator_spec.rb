require "rails_helper"
require "rails/generators"
require "generators/standard_audit/add_previous_checksum/add_previous_checksum_generator"

RSpec.describe StandardAudit::Generators::AddPreviousChecksumGenerator do
  let(:destination_root) { File.expand_path("../../../tmp/add_previous_checksum_test", __dir__) }

  before do
    FileUtils.rm_rf(destination_root)
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
  end

  after { FileUtils.rm_rf(destination_root) }

  def migration_content
    Dir.chdir(destination_root) do
      generator = described_class.new([], {})
      generator.destination_root = destination_root
      generator.invoke_all
    end

    File.read(Dir.glob(File.join(destination_root, "db/migrate/*_add_previous_checksum_to_audit_logs.rb")).first)
  end

  it "adds the column and its indexes without rewriting any row" do
    content = migration_content

    expect(content).to include("add_column :audit_logs, :previous_checksum, :string, limit: 64")
    expect(content).to include("add_index :audit_logs, :previous_checksum")
    expect(content).to include("add_index :audit_logs, [:created_at, :id]")
    expect(content).not_to include("update")
  end

  it "guards every step so it can repair a table that already has the column" do
    content = migration_content

    expect(content).to include("unless column_exists?(:audit_logs, :previous_checksum)")
    expect(content).to include("add_index :audit_logs, :previous_checksum unless index_exists?(:audit_logs, :previous_checksum)")
    expect(content).to include("unless index_exists?(:audit_logs, [:created_at, :id])")
    expect(content).to include("unless index_exists?(:audit_logs, :checksum)")
  end

  describe "running the generated migration" do
    let(:connection) { ActiveRecord::Base.connection }

    # The dummy app ships its own AddPreviousChecksumToAuditLogs, so the
    # generated file is evaluated under a name of its own.
    def migration
      code = migration_content.sub("class AddPreviousChecksumToAuditLogs", "class GeneratedPreviousChecksumMigration")
      Object.send(:remove_const, :GeneratedPreviousChecksumMigration) if Object.const_defined?(:GeneratedPreviousChecksumMigration)
      eval(code, TOPLEVEL_BINDING) # rubocop:disable Security/Eval
      GeneratedPreviousChecksumMigration.new.tap { |m| m.verbose = false }
    end

    it "rolls back the column and re-applies cleanly" do
      m = migration

      m.migrate(:down)
      expect(connection.column_exists?(:audit_logs, :previous_checksum)).to be(false)

      m.migrate(:up)
      expect(connection.column_exists?(:audit_logs, :previous_checksum)).to be(true)
      expect(connection.index_exists?(:audit_logs, :previous_checksum)).to be(true)
      expect(connection.index_exists?(:audit_logs, [:created_at, :id])).to be(true)
      expect(connection.index_exists?(:audit_logs, :checksum)).to be(true)
    end

    it "repairs a missing index when the column already exists" do
      m = migration
      connection.remove_index :audit_logs, :checksum if connection.index_exists?(:audit_logs, :checksum)

      expect { m.migrate(:up) }.not_to raise_error
      expect(connection.index_exists?(:audit_logs, :checksum)).to be(true)
    end
  end

  it "points at the relink task rather than leaving existing rows unexplained" do
    expect(migration_content).to include("standard_audit:relink_checksums")
  end
end
