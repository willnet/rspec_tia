require 'fileutils'
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
      # parallel_tests のプロセス数は取得側から分からないため、404 になるまで順に試す
      MAX_TEST_PROCESSES = 8

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

      # MR差分・pipeline/job一覧には通常のCI_JOB_TOKENでは足りない。
      def auth_header
        token = ENV['RSPEC_TIA_GITLAB_TOKEN']
        if token.to_s.empty?
          raise AuthenticationError,
                'GitLab APIにはRSPEC_TIA_GITLAB_TOKEN（read_api権限）が必要です。CI_JOB_TOKENだけではMR差分・マップ検索に対応しません'
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
        each_page("/projects/#{project_id}/pipelines/#{pipeline_id}/jobs?scope[]=success") { |job| jobs << job }
        jobs
      end

      # parallel なジョブ名は "rails_spec_tia_map 3/18" のようになるため前方一致で見る
      def map_job?(name)
        expected = options['map_job_name']
        return false if expected.to_s.empty?

        name == expected || name.start_with?("#{expected} ")
      end

      def download_fragments(job, dest_dir)
        node = parallel_index(job['name'])
        saved = []

        (1..MAX_TEST_PROCESSES).each do |process|
          artifact = File.join(fragment_dir_in_artifact, "map-#{node}-#{process}.json.gz")
          output = File.join(dest_dir, "job_#{job['id']}_map-#{node}-#{process}.json.gz")
          begin
            File.binwrite(output, http.get(artifact_path(job['id'], artifact)))
            saved << output
          rescue Http::NotFound
            # プロセス数を超えたファイル名は必ず404になる。そこで当該ジョブの取得を打ち切る
            break
          rescue Http::Error => e
            # 一時的な失敗では後続プロセス分が取れる可能性があるため、次を試す
            warn "[rspec_tia] skip #{job['name']} #{artifact}: #{e.message}"
          end
        end
        saved
      end

      def artifact_path(job_id, artifact)
        "/projects/#{project_id}/jobs/#{job_id}/artifacts/#{artifact}"
      end

      # artifact 内のパスは、生成側の map.fragment_dir とプロジェクトルートからの相対で一致する
      def fragment_dir_in_artifact
        options['map_artifact_glob'] || @config.map_fragment_dir
      end

      def parallel_index(job_name)
        match = job_name.match(%r{ (\d+)/\d+\z})
        match ? match[1] : '1'
      end
    end
  end
end
