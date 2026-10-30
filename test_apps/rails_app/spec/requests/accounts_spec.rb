RSpec.describe 'accounts page' do
  it 'renders the routed controller and ERB template' do
    response = Rack::MockRequest.new(Rails.application).get('/accounts')
    expect(response.status).to eq(200)
    expect(response.body).to include('<h1>Fixture accounts</h1>')
    expect(response.body).to include('Fixture navigation', '<span>Ada</span>', '<section>')
    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe('render_collection.action_view') do |*, payload|
      payloads << payload
    end
    begin
      response = Rack::MockRequest.new(Rails.application).get('/accounts')
      expect(response.status).to eq(200)
      expect(payloads.map { |payload| payload[:cache_hits] }).to include(2)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end
end
