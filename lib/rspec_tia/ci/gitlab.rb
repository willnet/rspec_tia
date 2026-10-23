require 'fileutils'
require 'stringio'
require 'tmpdir'
require 'zip'
require 'rspec_tia/http'
require 'rspec_tia/ci/base'

module RspecTia
  module Ci
    # GitLab CI アダプタ。
    #
    # 変更ファイルの取得に git を使わないのは、CIが浅いクローン（GIT_DEPTH）で動いていると
    # ターゲットブランチとの共通祖先が手元に無く `git diff origin/master...HEAD` が使えないため。
    # MRのdiffはAPIから取る。
    class Gitlab < Base
      class AuthenticationError < StandardError; end

      PER_PAGE = 100

      def self.available?
        !ENV['CI_API_V4_URL'].to_s.empty? && !ENV['CI_PROJECT_ID'].to_s.empty?
      end

      def merge_request?
        ENV['CI_PIPELINE_SOURCE'] == 'merge_request_event'
      end

      def labels
        ENV['CI_MERGE_REQUEST_LABELS'].to_s.split(',').map(&:strip).reject(&:empty?)
      end

      def commit_message
        ENV['CI_COMMIT_MESSAGE']
      end

      def changed_files
        iid = ENV['CI_MERGE_REQUEST_IID']
        return [] if iid.to_s.empty?

        paths = []
        each_page("/projects/#{project_id}/merge_requests/#{iid}/diffs") do |diff|
          # リネームや削除では旧パスの依存も実行対象に含める必要がある
          paths << diff['new_path'] unless diff['deleted_file']
          paths << diff['old_path']
        end
        paths.compact.uniq
      end

      def fetch_map_fragments(dest_dir)
        pipeline = latest_map_pipeline
        if pipeline.nil?
          warn '[rspec_tia] No map-generation pipeline found'
          return []
        end

        warn "[rspec_tia] Map source pipeline: #{pipeline['id']} (#{pipeline['created_at']})"
        FileUtils.mkdir_p(dest_dir)

        jobs = pipeline_jobs(pipeline['id']).select { |job| map_job?(job['name']) }
        validate_map_jobs!(jobs)
        # 一時領域で全件検証し、失敗時は部分的な断片も公開しない。
        Dir.mktmpdir('fetch-', dest_dir) do |staging|
          fragments = jobs.flat_map do |job|
            downloaded = download_fragments(job, staging)
            raise Map::FormatError, "No map fragments found for #{job['name']}" if downloaded.empty?

            downloaded.each { |path| validate_fragment!(path, pipeline) }
            downloaded
          end
          fragments.map do |path|
            output = File.join(dest_dir, File.basename(path))
            FileUtils.mv(path, output)
            output
          end
        end
      end

      private

      def options = @config.gitlab_options
      def project_id = ENV.fetch('CI_PROJECT_ID')

      def http
        @http ||= Http.new(
          base_url: ENV.fetch('CI_API_V4_URL'),
          headers: auth_header,
        )
      end

      # MR差分・pipeline/job一覧には通常のCI_JOB_TOKENでは足りない。
      def auth_header
        token = ENV['RSPEC_TIA_GITLAB_TOKEN']
        if token.to_s.empty?
          raise AuthenticationError,
                'GitLab API requires RSPEC_TIA_GITLAB_TOKEN with read_api scope. CI_JOB_TOKEN alone does not support MR diffs or map discovery'
        end

        { 'PRIVATE-TOKEN' => token }
      end

      def each_page(path)
        page = 1
        loop do
          separator = path.include?('?') ? '&' : '?'
          chunk = http.get_json("#{path}#{separator}per_page=#{PER_PAGE}&page=#{page}")
          break if chunk.empty?

          chunk.each { |item| yield item }
          break if chunk.size < PER_PAGE

          page += 1
        end
      end

      def latest_map_pipeline
        query = [
          "ref=#{options.fetch('map_ref')}",
          'status=success',
          "source=#{options.fetch('map_pipeline_source')}",
          'per_page=1',
        ].join('&')
        http.get_json("/projects/#{project_id}/pipelines?#{query}").first
      end

      def pipeline_jobs(pipeline_id)
        jobs = []
        each_page("/projects/#{project_id}/pipelines/#{pipeline_id}/jobs?include_retried=false") { |job| jobs << job }
        jobs
      end

      # parallel なジョブ名は "rails_spec_tia_map 3/18" のようになるため前方一致で見る
      def map_job?(name)
        expected = options['map_job_name']
        return false if expected.to_s.empty?

        name == expected || name.start_with?("#{expected} ")
      end

      # 成功したノードだけを列挙すると、失敗/欠落ノードを完全なマップと誤認する。
      def validate_map_jobs!(jobs)
        expected = options['map_job_name']
        raise Map::FormatError, "No map-generation jobs found: #{expected.inspect}" if jobs.empty?
        unless jobs.all? { |job| job['status'] == 'success' }
          raise Map::FormatError, 'Not all map-generation jobs succeeded'
        end
        return if jobs.size == 1 && jobs.first['name'] == expected

        matches = jobs.map { |job| job['name'].match(/\A#{Regexp.escape(expected)} (\d+)\/(\d+)\z/) }
        if matches.any?(&:nil?)
          raise Map::FormatError, 'Map-generation job names must use a single job name or the name index/total format'
        end
        totals = matches.map { |match| match[2].to_i }.uniq
        indices = matches.map { |match| match[1].to_i }.sort
        unless totals.size == 1 && totals.first.positive? && indices == (1..totals.first).to_a
          raise Map::FormatError, 'Map-generation nodes are missing or duplicated'
        end
      end

      def validate_fragment!(path, pipeline)
        map = Map.load(path)
        raise Map::FormatError, "Empty map fragment: #{path}" if map.empty?
        raise Map::FormatError, "Invalid or stale map fragment: #{path}" if map.stale?(max_age_days: @config.map_max_age_days)
        if pipeline['sha'] && map.commit_sha != pipeline['sha']
          raise Map::FormatError, "Map fragment does not match the source commit: #{path}"
        end
      rescue JSON::ParserError, Zlib::Error, KeyError, TypeError, ArgumentError => e
        raise Map::FormatError, "Cannot validate map fragment: #{path}: #{e.message}"
      end

      # 命名規則やプロセス数を推測せず、job artifactの一覧を使う。
      def download_fragments(job, dest_dir)
        archive = http.get("/projects/#{project_id}/jobs/#{job['id']}/artifacts")
        saved = []
        Zip::File.open_buffer(StringIO.new(archive)) do |zip|
          saved = zip.entries.reject(&:directory?).select { |entry| fragment_entry?(entry.name) }.sort_by(&:name)
             .each_with_index.map do |entry, index|
            # artifact内のパスは出力先に使わず、重複名やパストラバーサルを避ける。
            output = File.join(dest_dir, "job_#{job['id']}_#{index}_#{File.basename(entry.name)}")
            File.binwrite(output, zip.get_input_stream(entry).read)
            output
          end
        end
        saved
      rescue Http::Error, Zip::Error => e
        raise Map::FormatError, "Cannot fetch artifacts for #{job['name']}: #{e.message}"
      end

      def fragment_entry?(name)
        return false unless name.end_with?('.json', '.json.gz')

        pattern = options['map_artifact_glob']
        if pattern.to_s.empty?
          pattern = @config.map_fragment_dir.delete_prefix("#{@config.root}/")
        end
        pattern = "#{pattern.chomp('/')}/**/*.json*" unless pattern.match?(/[\*?\[{]/) || pattern.end_with?('.json', '.json.gz')
        File.fnmatch?(pattern, name, Configuration::FNMATCH_FLAGS)
      end
    end
  end
end
