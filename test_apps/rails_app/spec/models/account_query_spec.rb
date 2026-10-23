RSpec.describe 'account SQL without instantiation' do
  it('counts records') { expect(Account.count).to eq(1) }
end
