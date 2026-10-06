require 'rspec_tia/cli'

RSpec.describe 'GitLab API認証' do
  around do |example|
    values = { 'CI_API_V4_URL' => 'https://gitlab.example.test/api/v4', 'CI_PROJECT_ID' => '42',
               'CI_MERGE_REQUEST_IID' => '7', 'CI_PIPELINE_SOURCE' => 'merge_request_event',
               'CI_JOB_TOKEN' => 'secret-job-token', 'RSPEC_TIA_GITLAB_TOKEN' => 'secret-api-token' }
    original = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    with_project(['spec/a_spec.rb']) do |root|
      @root = root
      File.write(File.join(root, '.rspec_tia.yml'), "ci:\n  adapter: gitlab\n")
      example.run
    end
  ensure
    original.each { |key, value| ENV[key] = value }
  end

  def cli(*arguments)
    RspecTia::Cli.start([*arguments, '--root', @root])
  end

  it 'JOB-TOKENだけでは通信せず、設定すべき変数と権限を伝える' do
    ENV.delete('RSPEC_TIA_GITLAB_TOKEN')
    expect(Net::HTTP).not_to receive(:start)
    expect { expect(cli('select')).to eq(1) }
      .to output(/RSPEC_TIA_GITLAB_TOKEN.*read_api/).to_stderr
  end

  it 'map fetchにもAPI tokenが必要で、古いマップを上書きしない' do
    ENV['RSPEC_TIA_GITLAB_TOKEN'] = ''
    config = RspecTia::Configuration.load(root: @root)
    map = RspecTia::Map.new(generated_at: Time.now).add('spec/a_spec.rb', ['lib/a.rb'])
    map.dump(config.map_path)
    original = File.binread(config.map_path)
    expect(Net::HTTP).not_to receive(:start)
    expect { expect(cli('map', 'fetch')).to eq(1) }.to output(/read_api/).to_stderr
    expect(File.binread(config.map_path)).to eq(original)
  end

  it 'MR差分リクエストにはPRIVATE-TOKENを設定する' do
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    allow(response).to receive(:body).and_return('[{"old_path":"lib/a.rb","new_path":"lib/b.rb"}]')
    connection = instance_double(Net::HTTP)
    expect(Net::HTTP).to receive(:start).and_yield(connection)
    expect(connection).to receive(:request) do |request|
      expect(request['PRIVATE-TOKEN']).to eq('secret-api-token')
      expect(request['JOB-TOKEN']).to be_nil
      expect(request.path).to include('/projects/42/merge_requests/7/diffs')
      response
    end
    adapter = RspecTia::Ci::Gitlab.new(RspecTia::Configuration.load(root: @root))
    expect(adapter.changed_files).to contain_exactly('lib/a.rb', 'lib/b.rb')
  end

  [['401', Net::HTTPUnauthorized], ['403', Net::HTTPForbidden], ['404', Net::HTTPNotFound]].each do |code, response_class|
    it "#{response_class}では非ゼロ終了し、トークンを表示しない" do
      response = response_class.new('1.1', code, 'Denied')
      connection = instance_double(Net::HTTP, request: response)
      allow(Net::HTTP).to receive(:start).and_yield(connection)
      diagnostic = nil
      allow_any_instance_of(RspecTia::Cli).to receive(:warn) { |_cli, message| diagnostic = message }
      expect { expect(cli('select')).to eq(1) }.to output('').to_stdout
      expect(diagnostic).to include(code)
      expect(diagnostic).not_to include('secret-api-token', 'secret-job-token')
    end
  end
end
