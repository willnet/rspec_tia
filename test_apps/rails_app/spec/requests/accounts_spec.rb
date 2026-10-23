RSpec.describe 'accounts page' do
  it 'renders the routed controller and ERB template' do
    response = Rack::MockRequest.new(Rails.application).get('/accounts')
    expect(response.status).to eq(200)
    expect(response.body).to include('<h1>Fixture accounts</h1>')
  end
end
