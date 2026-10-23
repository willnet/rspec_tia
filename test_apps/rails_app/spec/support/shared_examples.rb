RSpec.shared_examples 'a shared example dependency' do
  it('executes the shared example service') { expect(SharedExampleValue.call).to eq('shared example') }
end
