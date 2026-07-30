class AddPreviousChecksumToAuditLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :audit_logs, :previous_checksum, :string, limit: 64
    add_index :audit_logs, :previous_checksum
    add_index :audit_logs, [:created_at, :id]
    add_index :audit_logs, :checksum
  end
end
