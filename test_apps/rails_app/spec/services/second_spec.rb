RSpec.describe 'second service consumer' do
  it('uses the shared service again') { expect(SharedValue.call).to eq('shared value') }
end
