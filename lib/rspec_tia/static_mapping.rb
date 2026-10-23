module RspecTia
  # Map source files to specs using naming conventions.
  #
  # Supplement coverage dependencies in three cases:
  #   - Newly added files absent from the map.
  #   - Files without executable method bodies, including those missed by ActiveRecord notifications.
  #   - Templates such as HAML that do not appear in coverage.
  #
  # Each rule pairs a source regex with a test template (or array); captures replace %s placeholders in order.
  # Discard nonexistent targets, naturally excluding mismatches caused by typos or singular/plural naming.
  class StaticMapping
    Rule = Struct.new(:pattern, :templates, keyword_init: true)

    def initialize(rules, root: Dir.pwd)
      @root = root
      @rules = Array(rules).map do |rule|
        Rule.new(
          pattern: Regexp.new("\\A(?:#{Array(rule.fetch('source')).join('|')})\\z"),
          templates: Array(rule.fetch('test')),
        )
      end
    end

    def call(paths)
      paths.flat_map { |path| specs_for(path) }.uniq
    end

    def specs_for(path)
      @rules.flat_map do |rule|
        match = rule.pattern.match(path)
        next [] if match.nil?

        expand(rule.templates, match.captures)
      end.uniq
    end

    private

    def expand(templates, captures)
      templates.filter_map do |template|
        candidate = format_template(template, captures)
        next if candidate.nil?

        candidate if File.exist?(File.join(@root, candidate))
      end
    end

    # Ignore a rule if its number of %s placeholders does not match the capture count.
    # A typo in one rule should not prevent the rest of the prediction from completing.
    def format_template(template, captures)
      format(template, *captures)
    rescue ArgumentError, TypeError
      warn "[rspec_tia] static_mapping template placeholders do not match capture groups: #{template.inspect} <- #{captures.inspect}"
      nil
    end
  end
end
