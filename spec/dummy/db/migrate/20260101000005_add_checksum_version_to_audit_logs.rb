class AddChecksumVersionToAuditLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :audit_logs, :checksum_version, :integer, limit: 2
  end
end
