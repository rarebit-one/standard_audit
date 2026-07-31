class AddDigestColumnsToUsers < ActiveRecord::Migration[8.1]
  def change
    # Secret-bearing columns exist so the record-dereferencing specs can assert
    # them ABSENT by name, the way `accounts.password_digest` and
    # `sessions.token_digest` were present in real audit rows
    # (rarebit-one/rarebit-ops#296).
    add_column :users, :password_digest, :string
    add_column :users, :token_digest, :string
  end
end
