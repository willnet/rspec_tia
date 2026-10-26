require 'rspec_tia/http'

RSpec.describe RspecTia::Http do
  subject(:http) { described_class.new(base_url: 'https://gitlab.example.test/api/v4', headers: { 'PRIVATE-TOKEN' => 'secret' }) }

  # Respond by request URI and record the headers sent to each one.
  def stub_responses(responses)
    requests = []
    connection = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:start).and_yield(connection)
    allow(connection).to receive(:request) do |request|
      requests << { uri: request.uri.to_s, token: request['PRIVATE-TOKEN'] }
      responses.fetch(request.uri.to_s).call
    end
    requests
  end

  def ok(body)
    Net::HTTPOK.new('1.1', '200', 'OK').tap { |response| allow(response).to receive(:body).and_return(body) }
  end

  def redirect(location)
    Net::HTTPFound.new('1.1', '302', 'Found').tap { |response| response['location'] = location }
  end

  it 'CDNへのリダイレクトを辿り、別オリジンにはトークンを送らない' do
    requests = stub_responses(
      'https://gitlab.example.test/api/v4/jobs/1/artifacts' => -> { redirect('https://cdn.example.test/a.zip?sig=x') },
      'https://cdn.example.test/a.zip?sig=x' => -> { ok('zip') },
    )

    expect(http.get('/jobs/1/artifacts')).to eq('zip')
    expect(requests).to eq [
      { uri: 'https://gitlab.example.test/api/v4/jobs/1/artifacts', token: 'secret' },
      { uri: 'https://cdn.example.test/a.zip?sig=x', token: nil },
    ]
  end

  it '同一オリジンへの相対リダイレクトではトークンを維持する' do
    requests = stub_responses(
      'https://gitlab.example.test/api/v4/old' => -> { redirect('/api/v4/new') },
      'https://gitlab.example.test/api/v4/new' => -> { ok('body') },
    )

    expect(http.get('/old')).to eq('body')
    expect(requests.map { |request| request[:token] }).to eq %w(secret secret)
  end

  it 'リダイレクト先の失敗は署名付きURLを含めず要求元URLで報告する' do
    stub_responses(
      'https://gitlab.example.test/api/v4/jobs/1/artifacts' => -> { redirect('https://cdn.example.test/a.zip?sig=x') },
      'https://cdn.example.test/a.zip?sig=x' => -> { Net::HTTPForbidden.new('1.1', '403', 'Forbidden') },
    )

    expect { http.get('/jobs/1/artifacts') }.to raise_error(described_class::Error) { |error|
      expect(error.message).to include('/api/v4/jobs/1/artifacts', '403')
      expect(error.message).not_to include('sig=x')
    }
  end

  it 'リダイレクトの上限を超えたら失敗する' do
    stub_responses('https://gitlab.example.test/api/v4/loop' => -> { redirect('/api/v4/loop') })

    expect { http.get('/loop') }.to raise_error(described_class::Error, /more than 5 redirects/)
  end

  ['', 'ftp://cdn.example.test/a.zip', 'http://[invalid'].each do |location|
    it "不正なLocation #{location.inspect} は失敗として扱う" do
      stub_responses('https://gitlab.example.test/api/v4/jobs/1/artifacts' => -> { redirect(location) })

      expect { http.get('/jobs/1/artifacts') }.to raise_error(described_class::Error, %r{/jobs/1/artifacts})
    end
  end

  it '通信エラーをErrorに包む' do
    allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNRESET)

    expect { http.get('/projects') }.to raise_error(described_class::Error, /ECONNRESET/)
  end
end
