ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :accounts, force: true do |table|
    table.string :name, null: false
  end
end
