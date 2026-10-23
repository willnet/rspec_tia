RSpec.describe 'first service consumer' do
  it('uses the shared service') { expect(SharedValue.call).to eq('shared value') }
end
