require 'open3'
require 'rspec_tia/ci/base'

module RspecTia
  module Ci
    # git だけで完結する汎用アダプタ。
    # クローンが浅いと共通祖先が手元に無く差分が取れないため、CI では専用アダプタを優先する。
    class Git < Base
      class CommandError < StandardError; end

      DEFAULT_BASE = 'origin/master'.freeze

      def self.available?
        system('git rev-parse --git-dir', out: File::NULL, err: File::NULL)
      end

      def merge_request?
        true
      end

      def changed_files
        output = capture('git', 'diff', '--name-only', '--no-renames', '-z', "#{base}...HEAD")
        output.split("\0")
      end

      def commit_message
        capture('git', 'log', '-1', '--pretty=%B')
      end

      private

      def base
        ENV['RSPEC_TIA_DIFF_BASE'] || DEFAULT_BASE
      end

      def capture(*command)
        stdout, stderr, status = Open3.capture3(*command, chdir: @config.root)
        unless status.success?
          raise CommandError, "Command failed: #{command.join(' ')}: #{stderr.strip}"
        end

        stdout
      end
    end
  end
end
