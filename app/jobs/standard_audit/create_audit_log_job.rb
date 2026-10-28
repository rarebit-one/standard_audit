module StandardAudit
  class CreateAuditLogJob < ActiveJob::Base
    queue_as { StandardAudit.config.queue_name }

    # `attrs` already carries actor/target/scope as the gid and type strings
    # the row stores (StandardAudit.persist serialised them at enqueue time),
    # so they are written as they are. Earlier versions located each record
    # only to serialise it back to the same strings, which cost up to three
    # SELECTs per row and failed the job outright (NameError) when a gid's
    # class no longer existed. A `before_checksum` hook that reads `log.actor` still gets the
    # record: the reader locates it lazily on first use.
    def perform(attrs)
      StandardAudit::AuditLog.new(attrs).save!
    end
  end
end
