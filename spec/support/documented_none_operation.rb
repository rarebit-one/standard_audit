# Fixture: declares `audit_none!` and explains itself in prose that happens to
# name the write path. Reproduces a real false failure — luminality-web's
# Api::Accounts::DeleteOperation carried the comment "No direct audit! here."
# and `unexpected_write_sites` flagged it, because the scan read raw source.
#
# The comment below is deliberately written the way a human would write it,
# with a bare `audit!` and no backticks. Backticking the token was the
# workaround before 0.9.1; a fixture that applies the workaround would assert
# nothing. See silent_operation.rb for why each fixture gets its own file.
class DocumentedNoneOperation
  include StandardAudit::Operation

  audit_none!

  # Deletion is recorded by the caller, so there is no direct audit! here.
  def execute
    # An earlier draft called audit!("account.deleted") here; removed when the
    # caller took over the record.
    :deleted
  end

  # Interpolation and a percent-literal containing a comment character, so the
  # comment stripper is exercised against the two constructs a naive
  # `#`-to-end-of-line regex would corrupt.
  def summary(name)
    "#{name} deleted" + %w[# ok].first
  end
end
