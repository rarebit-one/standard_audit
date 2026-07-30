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

  it "points at the relink task rather than leaving existing rows unexplained" do
    expect(migration_content).to include("standard_audit:relink_checksums")
  end
end
