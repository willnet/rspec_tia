module RspecTia
  # Prediction inputs collected by a CI adapter.
  # Normalize adapter differences here so Predictor and downstream logic remain CI-independent.
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
