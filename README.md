# rspec_tia

Test Impact Analysis for RSpec. Build a dependency map from code coverage, then select the spec files affected by changed files.

> Under development (v0.1.0, unreleased). Interfaces may change.

## Requirements and installation

Ruby 3.3 or later and RSpec Core 3.9 or later are required. Add the gem to your test dependencies once it is available:

```ruby
group :test do
  gem 'rspec_tia'
end
```

Run `bundle install`. While the gem is unreleased, use a local checkout with `gem 'rspec_tia', path: '/path/to/rspec_tia'`.

## Workflow

1. Run the full suite periodically on your default branch to generate a dependency map.
2. Make that map available to change pipelines, using CI artifacts or your own transfer mechanism.
3. Select and run affected specs for each change.
4. Keep running full-suite checks and audit the predictions to detect missed failures.

Selection combines coverage dependencies, static mappings, and changed spec files themselves. Missing or stale maps trigger a full run. Configured paths, labels, commit message tokens, and large changes can also force a full run.

## Configuration

Create `.rspec_tia.yml` in your project root. The paths and static mappings below are examples: adapt them to your application. Full-run paths, labels, tokens, and static mappings are empty by default.

```yaml
spec_glob: 'spec/**/*_spec.rb'
full_run_token: spec

map:
  fragment_dir: tmp/rspec_tia/fragments
  path: tmp/rspec_tia/map.json.gz
  max_age_days: 3

# Changes that coverage cannot reliably track should trigger a full run.
full_run:
  paths:
    - Gemfile.lock
    - config/**/*
    - db/**/*
    - spec/rails_helper.rb
    - spec/support/**/*
    - .gitlab-ci.yml
  max_changed_files: 300
  labels:
    - 'pipeline:run-all-rspec'
  commit_message_tokens:
    - '[run-all-rspec]'

# Regex capture groups replace each %s in order. Only existing specs are selected.
static_mapping:
  - source: 'app/(models|jobs)/(.+)\.rb'
    test: 'spec/%s/%s_spec.rb'
  - source: 'app/controllers/(.+)_controller\.rb'
    test: 'spec/requests/%s_request_spec.rb'
  - source: 'app/views/([^/]+)/.+'
    test: 'spec/requests/%s_request_spec.rb'

rails:
  enabled: auto
  active_record: true

ci:
  adapter: auto  # auto | gitlab | git

metrics_path: tmp/rspec_tia/metrics.json
```

Path globs use Ruby's `File.fnmatch?` with `FNM_PATHNAME | FNM_EXTGLOB`. Use `config/**/*` for nested paths; `config/**` does not match nested files. Static mapping sources are regular expressions, rather than path globs.

Rails support is enabled automatically when Rails is loaded. ActiveRecord tracking supplements coverage for model dependencies that coverage alone may miss.

## Generate a map

Run from the project root, starting coverage before the application loads:

```bash
RUBYOPT="-rrspec_tia/boot" bundle exec rspec \
  --require rspec_tia/formatter --format RspecTia::Formatter
bundle exec rspec-tia map merge
```

The formatter writes `map-<node>-<process>.json.gz` fragments under `map.fragment_dir`, using `CI_NODE_INDEX` and `TEST_ENV_NUMBER` when available. Collect fragments from all parallel workers before merging. Clear old fragments before each map generation so that previous runs cannot contaminate the map. Maps from failed tests or hooks are marked stale and cause selection to fall back to a full run.

Use `RSPEC_TIA_FRAGMENT_PATH` to override the fragment output path. `map merge --fragments DIR --output PATH` overrides the merge input directory and output file.

## Select and run specs

This Bash script runs selection from the project root, skips RSpec when no specs are selected, and fails the job if selection fails:

```bash
#!/usr/bin/env bash
bundle exec rspec-tia select > specs.txt || exit "$?"
[ -s specs.txt ] || exit 0

specs=()
while IFS= read -r spec; do
  specs+=("$spec")
done < specs.txt
bundle exec rspec "${specs[@]}"
```

Selection prints one path per line to standard output and a metrics summary to standard error. Metrics are also written to `metrics_path`; use `select --metrics PATH` to override it. `select --junit-dir DIR` uses JUnit timings to estimate time savings.

When a full run is required, output contains only `full_run_token` (default: `spec`). Set this to a directory or another value RSpec accepts as a single argument. If a separate splitting script consumes a custom token, that script must translate it into a full run.

The Bash array preserves spaces, backslashes, and wildcard characters in output paths. Filenames containing newlines are unsupported.

### Local Git and explicit changes

The Git adapter compares `origin/master...HEAD` by default. Set `RSPEC_TIA_DIFF_BASE` to use another base, such as `origin/main`. The base and common ancestor must be available locally; shallow clones may need more history. Supply a locally generated map when using this adapter.

To supply changed paths directly, use a newline-delimited file or standard input:

```bash
git diff --name-only HEAD~1 | bundle exec rspec-tia select --changed-files-from -
```

This is useful for evaluating predictions against historical changes before enabling selective execution in CI.

## GitLab CI integration

### Authentication

The GitLab adapter targets GitLab 17+ API v4 and uses `PRIVATE-TOKEN` authentication for MR diffs, pipeline/job discovery, and artifact downloads. Set `RSPEC_TIA_GITLAB_TOKEN` to a personal access token with `read_api`, or an equivalent project/group access token. Its owner needs access to the project's code, merge requests, and CI artifacts (typically Reporter or higher). A separate token is required even within the same project. Deploy tokens are unsupported.

Register the token as a masked CI/CD variable. If it is protected, ensure it is available to the MR pipelines that run selection. Missing tokens and API failures produce a nonzero exit status; they are not treated as an empty change list.

A normal `CI_JOB_TOKEN` does not cover all APIs needed by this adapter. See GitLab's [job token access documentation](https://docs.gitlab.com/ci/jobs/ci_job_token/#job-token-access), [access token scopes](https://docs.gitlab.com/user/profile/personal_access_tokens/#personal-access-token-scopes), and [MR diffs API](https://docs.gitlab.com/api/merge_requests/#list-merge-request-diffs).

### Map artifacts

Configure the source of the map artifacts:

```yaml
ci:
  adapter: gitlab
  gitlab:
    map_ref: main  # Default: master; set this to your default branch.
    map_pipeline_source: schedule
    map_job_name: rspec-map
    map_artifact_glob: tmp/rspec_tia/fragments
```

Save the entire `map.fragment_dir` directory as an artifact from each map-generation job. In the selection job, fetch and merge the fragments before selecting specs:

```bash
bundle exec rspec-tia map fetch || exit "$?"
bundle exec rspec-tia select > specs.txt || exit "$?"
# Run the selected specs using the Bash script above.
```

`map_artifact_glob` accepts a project-relative directory, glob, or fragment file path. The adapter reads matching `.json` and `.json.gz` fragments from job artifact ZIPs. If you override `RSPEC_TIA_FRAGMENT_PATH`, include that file in artifacts and adjust the matching path.

Supported job names are a single `map_job_name` or GitLab numeric parallel names such as `rspec-map 1/4`. All nodes must succeed and provide valid, fresh fragments from the same commit. Incomplete or invalid downloads fail and preserve the existing merged map. Other naming formats, including `parallel:matrix`, are unsupported. Ensure each job saves fragments from every process, and propagate RSpec and artifact-upload failures.

When no map fragments are available through the adapter's normal no-map path, `map fetch` removes the existing merged map so selection falls back to a full run. Artifact HTTP failures, including 404 responses, are errors. Use `map fetch --no-merge` to download without merging, or `--dest DIR` to change the download directory.

## Audit and diagnostics

```bash
bundle exec rspec-tia audit --junit tmp/junit --predicted specs.txt
bundle exec rspec-tia doctor
```

`audit` compares predictions with JUnit results from a full-suite run and exits with status 1 if a failing spec was omitted. Keep auditing full-suite runs after enabling selection to detect missed failures. `doctor` checks configuration, spec discovery, map freshness, the CI adapter, and static mappings.

Commands accept `--config PATH` and `--root PATH` to override the configuration file and project root.

## Limitations

- Templates such as HAML and ERB are not captured by Ruby coverage. Add static mappings.
- Files without executable method bodies may be missed. ActiveRecord support supplements model dependencies; use static mappings for other cases.
- Dependencies on external services and data files are not detected. Add relevant paths to `full_run.paths`.
- Changes to widely shared concerns or modules may still select most of the suite.

## Development documentation

- [Rails correctness fixture: execution, expected dependencies, and mutations](test_apps/rails_app/README.md)
- [Design decisions and architecture](docs/design.md)
- [Agent and contributor instructions](AGENTS.md)

## License

MIT
