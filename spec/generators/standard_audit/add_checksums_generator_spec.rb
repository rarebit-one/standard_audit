require "rails_helper"
require "rails/generators"
require "generators/standard_audit/add_checksums/add_checksums_generator"

RSpec.describe StandardAudit::Generators::AddChecksumsGenerator do
  let(:destination_root) { File.expand_path("../../../tmp/add_checksums_test", __dir__) }

  before do
    FileUtils.rm_rf(destination_root)
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
  end

  after { FileUtils.rm_rf(destination_root) }

  def run_generator
    generator = described_class.new([], {}, destination_root: destination_root)
    generator.invoke_all
  end

  it "warns that it is deprecated but still generates the migration" do
    expect {
      expect { run_generator }.to output(/deprecated/).to_stdout
    }.to output(/DEPRECATION: standard_audit:add_checksums is deprecated/).to_stderr

    expect(Dir.glob(File.join(destination_root, "db/migrate/*_add_checksum_to_audit_logs.rb"))).not_to be_empty
  end
end
