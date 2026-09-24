class AddAnonymizedAtToAuditLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :audit_logs, :anonymized_at, :datetime
  end
end
