class CreateTestModels < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :name
      t.string :email
      t.timestamps
    end

    create_table :organisations do |t|
      t.string :name
      t.timestamps
    end

    create_table :orders do |t|
      t.references :user
      t.references :organisation
      t.decimal :total
      t.timestamps
    end
  end
end
