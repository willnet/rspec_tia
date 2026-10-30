RSpec.describe 'users page' do
  it 'renders the shared partial, collection, and layout again in the same process' do
    2.times do
      response = Rack::MockRequest.new(Rails.application).get('/users')
      expect(response.status).to eq(200)
      expect(response.body).to include('<h1>Fixture users</h1>', 'Fixture navigation', '<span>Ada</span>')
    end
  end
end
