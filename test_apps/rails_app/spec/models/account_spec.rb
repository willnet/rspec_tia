RSpec.describe 'account instantiation and validation' do
  it 'instantiates a valid account from SQL' do
    account = Account.first!
    expect(account.name).to eq('Ada')
    expect(account).to be_valid
  end
end
