require "rails/generators/migration"
require "time"

module StandardAudit
  module Generators
    # Migration numbering shared by the gem's migration generators.
    #
    # A plain `Time.now` stamp sorts BEFORE a host's future-dated migrations
    # (several consumers date theirs ahead of the clock), so the generated
    # migration would run out of order and look already-applied to tools that
    # compare against the latest version. This picks whichever is later: now,
    # or one second after the newest migration already in the target
    # directory. (ActiveRecord's own generators add 1 to the number, which
    # can produce an invalid timestamp such as ...235960; this adds a second.)
    module MigrationNumber
      def self.included(base)
        base.include Rails::Generators::Migration
        base.extend ClassMethods
      end

      module ClassMethods
        FORMAT = "%Y%m%d%H%M%S".freeze

        def next_migration_number(dirname)
          [Time.now.utc.strftime(FORMAT), one_second_after(current_migration_number(dirname))].max
        end

        private

        def one_second_after(number)
          stamp = Kernel.format("%.14d", number)
          (Time.strptime("#{stamp} +0000", "#{FORMAT} %z") + 1).utc.strftime(FORMAT)
        rescue ArgumentError
          # Not a timestamp (no migrations yet, or a sequential numbering).
          Kernel.format("%.14d", number + 1)
        end
      end
    end
  end
end
