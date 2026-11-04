require_relative '../support/rails_app_runner'

RSpec.describe 'Rails application prediction oracle' do
  it 'selects templates, new sources, changed specs, and configuration from handwritten expectations' do
    RailsAppRunner.with_app(mode: :eager) do |app|
      baseline = app.run.map
      app.expectations('predictions').each do |name, entry|
        expect(entry.fetch('description')).not_to be_empty
        if entry.key?('added_source')
          path = File.join(app.root, entry.fetch('added_source'))
          expect(File.exist?(path)).to be(false)
          expect(baseline.known_source?(entry.fetch('added_source'))).to be(false)
          File.write(path, entry.fetch('added_content'))
        end
        changed = entry.fetch('changed_files')
        expected = entry.fetch('specs') == 'all' ? app.all_specs : entry.fetch('specs')
        app.validate_paths!(changed + expected)
        map = baseline
        if entry['static_only']
          # Erase all runtime edges while retaining map freshness and the independent spec inventory.
          map = RspecTia::Map.new(generated_at: baseline.generated_at)
          app.all_specs.each { |spec| map.add(spec, []) }
        end
        prediction = app.predict(map, changed)
        expect(prediction.full_run?).to eq(entry.fetch('full_run', false)), name
        expect(prediction.reason).to eq(entry['reason']), name
        expect(prediction.specs).to match_array(expected),
          "#{name} mode=eager sources=#{changed} missing=#{expected - prediction.specs} extra=#{prediction.specs - expected}"
      end
    end
  end

  it 'detects independent injected bugs using only a pre-change map and assertion failures' do
    RailsAppRunner.with_app(mode: :eager) do |baseline_app|
      baseline = baseline_app.run.map
      original_map = baseline.to_h
      baseline_app.expectations('mutations').each do |name, mutation|
        RailsAppRunner.with_app(mode: :eager) do |app|
          expect(mutation.fetch('description')).not_to be_empty
          expected_failures = mutation.fetch('failed_specs')
          forbidden = mutation.fetch('forbidden_specs', [])
          app.validate_paths!(expected_failures + forbidden)
          app.mutate!(mutation)
          prediction = app.predict(baseline, [mutation.fetch('source')])
          expect(prediction.full_run?).to be(false), name
          expect(prediction.specs & forbidden).to be_empty, name
          full = app.run(mapping: false)
          full_failures = app.assertion_failures!(full)
          expect(full_failures).to match_array(expected_failures), "#{name}\n#{full.diagnostic}"
          expect(full_failures - prediction.specs).to be_empty,
            "#{name} missing failing specs=#{full_failures - prediction.specs}"
          expect(prediction.specs).not_to be_empty
          selected = app.run(mapping: false, specs: prediction.specs)
          expect(app.assertion_failures!(selected)).to match_array(full_failures), "#{name}\n#{selected.diagnostic}"
          expect(Dir.glob(File.join(app.root, 'tmp/**/*.json.gz'))).to be_empty
          expect(baseline.to_h).to eq(original_map)
        end
      end
    end
  end
end
