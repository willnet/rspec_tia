require_relative '../support/rails_app_runner'

RSpec.describe 'ActionView runtime dependencies' do
  [
    [{}, true],
    [{ 'active_record' => false }, true],
    [{ 'action_view' => false }, false],
    [{ 'enabled' => false }, false],
  ].each do |options, enabled|
    it "honors rails=#{options.inspect} after spec-time Rails loading without static mappings" do
      RailsAppRunner.with_app(mode: :normal) do |app|
        path = File.join(app.root, '.rspec_tia.yml')
        config = YAML.safe_load_file(path).merge('rails' => options, 'static_mapping' => [])
        File.write(path, YAML.dump(config))
        map = app.run.map
        expected = enabled ? %w[spec/requests/accounts_spec.rb spec/requests/users_spec.rb] : []
        sources = %w[app/views/shared/_navigation.html.erb app/views/shared/_item.html.erb app/views/layouts/application.html.erb]
        # Exercise both persistence and multi-fragment merge before predicting from template paths.
        saved = File.join(app.root, 'tmp/roundtrip.json.gz')
        map.dump(saved)
        map = RspecTia::Map.merge_files([saved, saved])
        sources.each do |source|
          expect(map.specs_for(source)).to match_array(expected)
          prediction = app.predict(map, [source])
          expect(prediction).not_to be_full_run
          expect(prediction.specs).to match_array(expected)
        end
        expect(map.specs_for('app/services/shared_value.rb')).to match_array(%w[spec/services/first_spec.rb spec/services/second_spec.rb])
      end
    end
  end

  it 'selects both consumers for changes to an internal symlink or its target without static mappings' do
    RailsAppRunner.with_app(mode: :normal) do |app|
      config_path = File.join(app.root, '.rspec_tia.yml')
      config = YAML.safe_load_file(config_path).merge('static_mapping' => [])
      File.write(config_path, YAML.dump(config))
      target = 'app/views/shared/_navigation_target.html.erb'
      link = 'app/views/shared/_navigation.html.erb'
      FileUtils.mv(File.join(app.root, link), File.join(app.root, target))
      File.symlink('_navigation_target.html.erb', File.join(app.root, link))
      map = app.run.map
      consumers = %w[spec/requests/accounts_spec.rb spec/requests/users_spec.rb]
      [link, target].each do |source|
        expect(map.specs_for(source)).to match_array(consumers)
        prediction = app.predict(map, [source])
        expect(prediction).not_to be_full_run
        expect(prediction.specs).to match_array(consumers)
      end
    end
  end

  it 'keeps coverage dependencies when rendering inline or external templates' do
    RailsAppRunner.with_app(mode: :normal) do |app|
      File.write(File.join(File.dirname(app.root), 'external.html.erb'), '<p>External</p>')
      File.write(File.join(app.root, 'spec/render_probe_spec.rb'), <<~'RUBY')
        RSpec.describe 'virtual and external templates' do
          it 'renders without introducing non-project dependencies' do
            expect(AccountsController.render(inline: '<p>Inline</p>', layout: false)).to include('Inline')
            external = File.expand_path('../../external.html.erb', __dir__)
            expect(AccountsController.render(file: external, layout: false)).to include('External')
            expect(SharedValue.call).to eq('shared value')
          end
        end
      RUBY
      map = app.run.map
      expect(map.sources.grep(/external|inline/)).to be_empty
      expect(map.specs_for('app/services/shared_value.rb')).to include('spec/render_probe_spec.rb')
    end
  end

  it 'exposes the nested-template gap on warm fragment and collection caches' do
    RailsAppRunner.with_app(mode: :normal) do |app|
      views = File.join(app.root, 'app/views/cache_probe')
      FileUtils.mkdir_p(views)
      File.write(File.join(views, '_nested.html.erb'), '<span>Nested</span>')
      File.write(File.join(views, '_fragment.html.erb'), <<~'ERB')
        <% cache 'probe-fragment' do %><%= render 'cache_probe/nested' %><% end %>
      ERB
      File.write(File.join(views, '_row.html.erb'), '<%= row %><%= render "cache_probe/nested" %>')
      File.write(File.join(app.root, 'spec/cache_probe_spec.rb'), <<~'RUBY')
        RSpec.describe 'warm cache notification limits' do
          it 'does not announce nested renders when a cached body is reused' do
            Rails.cache.clear
            ActionView::PartialRenderer.collection_cache.clear
            events = []
            token = ActiveSupport::Notifications.subscribe('!render_template.action_view') do |*, payload|
              events << payload[:identifier]
            end
            begin
              2.times do |iteration|
                events.clear
                expect(AccountsController.render(partial: 'cache_probe/fragment')).to include('Nested')
                expect(events.grep(/_nested/).empty?).to eq(iteration == 1)
              end
              2.times do |iteration|
                events.clear
                body = AccountsController.render(partial: 'cache_probe/row', collection: ['Ada'], cached: true)
                expect(body).to include('Nested')
                expect(events.grep(/_nested/).empty?).to eq(iteration == 1)
              end
            ensure
              ActiveSupport::Notifications.unsubscribe(token)
            end
          end
        end
      RUBY
      map = app.run.map
      %w[nested fragment row].each do |name|
        expect(map.specs_for("app/views/cache_probe/_#{name}.html.erb")).to contain_exactly('spec/cache_probe_spec.rb')
      end
    end
  end
end
