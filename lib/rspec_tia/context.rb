module RspecTia
  # CIアダプタが集めた「予測に必要な入力」。
  # アダプタごとの差異をここで吸収し、Predictor から下はCI非依存にする。
  Context = Struct.new(
    :changed_files,
    :labels,
    :commit_message,
    :merge_request,
    keyword_init: true,
  ) do
    def merge_request? = !!merge_request

    def initialize(changed_files: [], labels: [], commit_message: nil, merge_request: false)
      super
    end
  end
end
