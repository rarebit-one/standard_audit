source "https://rubygems.org"

# Specify your gem's dependencies in standard_audit.gemspec.
# The minimum Ruby version is declared in standard_audit.gemspec
# (required_ruby_version) so the gem stays installable on any supported
# patch release; CI runs against the full 4.x matrix.
gemspec

gem "puma"

gem "sqlite3"

group :development, :test do
  gem "rspec-rails", "~> 8.0"
  gem "shoulda-matchers", "~> 7.0"
end

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false
gem "brakeman", require: false
gem "bundler-audit", require: false
