require "spec_helper"

abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"
require "shoulda/matchers"

# In-memory SQLite starts empty, so migrations simply run. A Postgres test
# database (DATABASE_URL, the CI Postgres leg) persists between runs, so its
# schema is dropped and rebuilt first — the dummy migrations are edited in
# place rather than appended to. Refuses any database whose name does not
# look like a throwaway test database.
connection = ActiveRecord::Base.connection
if connection.adapter_name.match?(/postg/i)
  database = connection.current_database
  abort("Refusing to reset #{database.inspect}: not a test database") unless database.include?("test")

  connection.execute("DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public")
  connection.schema_cache.clear!
  ActiveRecord::Base.descendants.each(&:reset_column_information)
end
ActiveRecord::Migration.verbose = false
ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate

Dir[File.join(__dir__, "support/**/*.rb")].sort.each { |file| require file }

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.filter_rails_from_backtrace!
  config.include ActiveSupport::Testing::TimeHelpers
end

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end
