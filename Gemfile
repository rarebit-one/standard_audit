source "https://rubygems.org"

ruby file: ".ruby-version"

# Specify your gem's dependencies in standard_audit.gemspec.
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
