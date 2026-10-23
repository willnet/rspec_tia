RSpec.describe 'an unrelated service' do
  it('uses only its own service') { expect(UnrelatedValue.call).to eq('unrelated') }
end
