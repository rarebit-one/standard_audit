require "rails_helper"
require "rails/generators"
require "generators/standard_audit/install/install_generator"

RSpec.describe StandardAudit::Generators::InstallGenerator do
  include FileUtils

  let(:destination_root) { File.expand_path("../../../tmp/generator_test", __dir__) }

  before do
    FileUtils.rm_rf(destination_root)
    FileUtils.mkdir_p(destination_root)

    # Set up the generator with the test destination
    allow(Rails).to receive(:root).and_return(Pathname.new(destination_root))
  end

  after do
    FileUtils.rm_rf(destination_root)
  end

  def run_generator(options = {})
    Dir.chdir(destination_root) do
      FileUtils.mkdir_p("db/migrate")
      FileUtils.mkdir_p("config/initializers")

      generator = described_class.new([], options)
      generator.destination_root = destination_root
      generator.invoke_all
    end
  end

  def migration_files
    Dir.glob(File.join(destination_root, "db/migrate/*_create_audit_logs.rb"))
  end

  def initializer_path
    File.join(destination_root, "config/initializers/standard_audit.rb")
  end

  it "creates migration file" do
    run_generator

    expect(migration_files.size).to eq(1)

    content = File.read(migration_files.first)
    expect(content).to include("create_table :audit_logs, id: :uuid")
    expect(content).to include("t.string :event_type, null: false")
    expect(content).to include("t.string :actor_gid")
    expect(content).to include("t.string :target_gid")
    expect(content).to include("t.string :scope_gid")
    expect(content).to include("t.jsonb :metadata")
    expect(content).to include("t.datetime :occurred_at, null: false")
    expect(content).to include("add_index :audit_logs, :event_type")
    expect(content).to include("add_index :audit_logs, [:actor_gid, :occurred_at]")
    expect(content).to include("add_index :audit_logs, [:target_gid, :occurred_at]")
    expect(content).to include("add_index :audit_logs, [:occurred_at, :created_at]")
    expect(content).to include("t.text :user_agent")
    expect(content).to include("Multi-tenancy: include StandardAudit::AuditScope")
    expect(content).to include("add_index :audit_logs, :metadata, using: :gin")
  end

  it "creates initializer file" do
    run_generator

    expect(File.exist?(initializer_path)).to be true

    content = File.read(initializer_path)
    expect(content).to include("StandardAudit.configure")
    expect(content).to include("config.subscribe_to")
  end

  context "when re-running on an existing install" do
    it "skips both pieces when migration and initializer already exist" do
      run_generator
      expect(migration_files.size).to eq(1)
      expect(File.exist?(initializer_path)).to be true

      original_migration = migration_files.first
      original_migration_content = File.read(original_migration)
      original_initializer_mtime = File.mtime(initializer_path)

      # Sleep briefly so any new migration would have a different timestamp
      # (next_migration_number is second-resolution).
      sleep 1.1

      run_generator

      # Migration: still exactly one file, unchanged
      expect(migration_files.size).to eq(1)
      expect(migration_files.first).to eq(original_migration)
      expect(File.read(original_migration)).to eq(original_migration_content)

      # Initializer: untouched
      expect(File.mtime(initializer_path)).to eq(original_initializer_mtime)
    end
  end

  context "with --skip-migration" do
    it "skips the migration but writes the initializer" do
      run_generator(skip_migration: true)

      expect(migration_files).to be_empty
      expect(File.exist?(initializer_path)).to be true
    end
  end

  context "with --skip-initializer" do
    it "skips the initializer but writes the migration" do
      run_generator(skip_initializer: true)

      expect(migration_files.size).to eq(1)
      expect(File.exist?(initializer_path)).to be false
    end
  end

  context "with --force" do
    it "overwrites the initializer" do
      run_generator
      expect(File.exist?(initializer_path)).to be true

      File.write(initializer_path, "# user customisation\n")
      expect(File.read(initializer_path)).to eq("# user customisation\n")

      run_generator(force: true, skip_migration: true)

      content = File.read(initializer_path)
      expect(content).not_to eq("# user customisation\n")
      expect(content).to include("StandardAudit.configure")
    end
  end
end
