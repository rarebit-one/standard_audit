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

  it "creates migration file" do
    # Use Rails::Generators.invoke to run the generator
    Dir.chdir(destination_root) do
      FileUtils.mkdir_p("db/migrate")
      FileUtils.mkdir_p("config/initializers")

      generator = described_class.new
      generator.destination_root = destination_root
      generator.invoke_all
    end

    migration_files = Dir.glob(File.join(destination_root, "db/migrate/*_create_audit_logs.rb"))
    expect(migration_files.size).to eq(1)

    content = File.read(migration_files.first)
    expect(content).to include("create_table :audit_logs, id: :uuid")
    expect(content).to include("t.string :event_type, null: false")
    expect(content).to include("t.string :actor_gid")
    expect(content).to include("t.string :target_gid")
    expect(content).to include("t.string :scope_gid")
    expect(content).to include("t.json :metadata")
    expect(content).to include("t.datetime :occurred_at, null: false")
    expect(content).to include("add_index :audit_logs, :event_type")
    expect(content).to include("add_index :audit_logs, [:actor_gid, :occurred_at]")
    expect(content).to include("add_index :audit_logs, [:target_gid, :occurred_at]")
    expect(content).to include("t.text :user_agent")
  end

  it "creates initializer file" do
    Dir.chdir(destination_root) do
      FileUtils.mkdir_p("db/migrate")
      FileUtils.mkdir_p("config/initializers")

      generator = described_class.new
      generator.destination_root = destination_root
      generator.invoke_all
    end

    initializer = File.join(destination_root, "config/initializers/standard_audit.rb")
    expect(File.exist?(initializer)).to be true

    content = File.read(initializer)
    expect(content).to include("StandardAudit.configure")
    expect(content).to include("config.subscribe_to")
  end
end
