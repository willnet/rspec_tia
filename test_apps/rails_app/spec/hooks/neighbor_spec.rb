RSpec.describe 'a neighboring spec without context dependencies' do
  it('has no context hooks') { expect('neighbor').to eq('neighbor') }
end
