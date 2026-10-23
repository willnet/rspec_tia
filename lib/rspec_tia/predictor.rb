require 'set'

module RspecTia
  # Select spec files affected by a list of changed files.
  #
  # Take the union of three sources:
  #   1. Reverse lookup in the coverage map (primary).
  #   2. Static mappings for new files, templates, and missed classes without executable bodies.
  #   3. Changed spec files themselves.
  class Predictor
    Result = Struct.new(:full_run, :reason, :specs, :sources, keyword_init: true) do
      def full_run? = !!full_run
    end

    def initialize(config:, map:)
      @config = config
      @map = map
      @static_mapping = StaticMapping.new(config.static_mapping_rules, root: config.root)
      @fallback = Fallback.new(config: config, map: map)
    end

    def call(context)
      reason = @fallback.reason(context)
      return Result.new(full_run: true, reason: reason, specs: @config.all_specs, sources: context.changed_files) if reason

      specs = Set.new
      context.changed_files.each { |path| specs.merge(@map.specs_for(path)) }
      specs.merge(@static_mapping.call(context.changed_files))
      specs.merge(context.changed_files.select { |path| spec_file?(path) })

      Result.new(full_run: false, reason: nil, specs: existing(specs).sort, sources: context.changed_files)
    end

    private

    def spec_file?(path)
      File.fnmatch?(@config.spec_glob, path, Configuration::FNMATCH_FLAGS)
    end

    # Exclude specs deleted or renamed since map generation.
    # Passing nonexistent paths to RSpec would fail the entire job.
    def existing(specs)
      specs.select { |path| File.exist?(File.join(@config.root, path)) }
    end
  end
end
