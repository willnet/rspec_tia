require 'fileutils'
require 'stringio'
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
          warn '[rspec_tia] マップ生成パイプラインが見つかりません'
          return []
        end

        warn "[rspec_tia] マップの取得元パイプライン: #{pipeline['id']} (#{pipeline['created_at']})"
        FileUtils.mkdir_p(dest_dir)

        pipeline_jobs(pipeline['id']).flat_map do |job|
          next [] unless map_job?(job['name'])

          download_fragments(job, dest_dir)
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

      # CI_JOB_TOKEN は同一プロジェクトの artifact 取得に使える。
      # 別プロジェクトから引く場合のために PRIVATE-TOKEN も受け付ける
      def auth_header
        token = ENV['RSPEC_TIA_GITLAB_TOKEN']
        return { 'PRIVATE-TOKEN' => token } unless token.to_s.empty?

        { 'JOB-TOKEN' => ENV.fetch('CI_JOB_TOKEN') }
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
        each_page("/projects/#{project_id}/pipelines/#{pipeline_id}/jobs?scope[]=success") { |job| jobs << job }
        jobs
      end

      # parallel なジョブ名は "rails_spec_tia_map 3/18" のようになるため前方一致で見る
      def map_job?(name)
        expected = options['map_job_name']
        return false if expected.to_s.empty?

        name == expected || name.start_with?("#{expected} ")
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
        raise Map::FormatError, "#{job['name']}のartifactを取得できません: #{e.message}"
      end

      def fragment_entry?(name)
        pattern = options['map_artifact_glob']
        if pattern.to_s.empty?
          pattern = @config.map_fragment_dir.delete_prefix("#{@config.root}/")
        end
        pattern = "#{pattern.chomp('/')}/**/*.json*" unless pattern.match?(/[\*?\[]/) || pattern.end_with?('.json', '.json.gz')
        File.fnmatch?(pattern, name, Configuration::FNMATCH_FLAGS)
      end
    end
  end
end
