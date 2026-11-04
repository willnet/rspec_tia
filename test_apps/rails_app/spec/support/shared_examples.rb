RSpec.shared_examples 'a shared example dependency' do
  it('renders a shared partial') do
    expect(AccountsController.render(partial: 'tracking/shared')).to include('<span>shared</span>')
  end
  it('executes the shared example service') { expect(SharedExampleValue.call).to eq('shared example') }
end
