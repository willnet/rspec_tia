module RspecTia
  # Supplement runtime coverage with the explicit target of each executed example.
  class DescribedClassSupport
    def initialize(root:)
      @root = "#{File.expand_path(root).delete_suffix('/')}/"
      @files = {}.compare_by_identity
      @locations = {}.compare_by_identity
    end

    def files_for(target)
      return [] unless target.is_a?(Module) && target.name && !target.name.empty?

      @files[target] ||= target.ancestors.filter_map do |ancestor|
        unless @locations.key?(ancestor)
          @locations[ancestor] = definition_file(ancestor)
        end
        @locations[ancestor]
      end.uniq.freeze
    end

    private

    def definition_file(target)
      name = target.name
      return if name.nil? || name.empty?

      owner = Object
      parts = name.split('::')
      parts[0...-1].each do |part|
        # Never trigger autoload while resolving a stale or removed constant path.
        return unless owner.is_a?(Module) && owner.const_defined?(part, false)
        return if owner.autoload?(part, false)

        owner = owner.const_get(part, false)
      end
      leaf = parts.last
      return unless owner.is_a?(Module) && owner.const_defined?(leaf, false)
      return if owner.autoload?(leaf, false)
      return unless owner.const_get(leaf, false).equal?(target)

      path = owner.const_source_location(leaf, false)&.first
      return unless path

      path = File.expand_path(path)
      path.delete_prefix(@root) if path.start_with?(@root) && File.file?(path)
    rescue NameError, TypeError
      # Removed constants and unresolvable names do not prevent map generation.
      nil
    end
  end
end
