require_relative '../support/rails_app_runner'

RSpec.describe 'Rails application dependency oracle' do
  [:normal, :eager].each do |mode|
    ['defined', 'rand:12', 'rand:97'].each do |order|
      it "records exactly the explained dependencies (#{mode}, #{order})" do
        RailsAppRunner.with_app(mode: mode) do |app|
          result = app.run(order: order)
          app.expectations('mapping').each do |name, entry|
            expect(entry.fetch('description')).not_to be_empty
            expected = entry.fetch('exact_specs')
            expected = app.all_specs if expected == 'all'
            app.validate_paths!([entry.fetch('source'), *expected])
            actual = result.map.specs_for(entry.fetch('source')).to_a
            expect(actual).to match_array(expected),
              "#{name} mode=#{mode} order=#{order} source=#{entry.fetch('source')}\n" \
              "missing=#{expected - actual} extra=#{actual - expected}\n#{result.diagnostic}"
          end
        end
      end
    end
  end

  it 'distinguishes ActiveRecord supplementation from initial model loading (M4)' do
    RailsAppRunner.with_app(mode: :without_ar) do |app|
      result = app.run
      entries = app.expectations('mapping').select { |_name, entry| entry.key?('exact_specs_without_ar') }
      expect(entries).not_to be_empty
      entries.each do |name, entry|
        expected = entry.fetch('exact_specs_without_ar')
        app.validate_paths!([entry.fetch('source'), *entry.fetch('exact_specs'), *expected])
        actual = result.map.specs_for(entry.fetch('source')).to_a
        expect(actual).to match_array(expected),
          "#{name} mode=without_ar source=#{entry.fetch('source')} missing=#{expected - actual} extra=#{actual - expected}\n#{result.diagnostic}"
      end
    end
  end
end
