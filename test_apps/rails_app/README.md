# Rails mapping oracle

This small Rails application checks dependency attribution and test selection against
handwritten answers. It is a correctness regression fixture, not a performance
benchmark. It uses Ruby 3.3+, Rails 7.2, RSpec 3.13, and SQLite from the repository's
root bundle. There is no separate Gemfile or `rspec-rails` dependency. Requests run
through Rack, routing, controllers, and ERB views without an HTTP server. ActionView
tracking is verified with Rails 7.2.4; other versions and HAML are not verified.
In-memory fragment and collection caching are enabled to test warm render paths.

From the repository root:

```sh
bundle install
bundle exec rspec spec/integration
bundle exec rspec
bundle exec rake spec
```

The ordinary suite discovers only `spec/**/*_spec.rb`. Specs under this application
run only in child processes of the integration suite.

## Running the application specs directly

The following commands use a temporary copy, just like the integration runner.
Run them from the repository root in a POSIX shell:

```sh
repository="$PWD"
workdir="$(mktemp -d)"
cp -R test_apps/rails_app "$workdir/app"
(
  cd "$workdir/app" || exit 1
  unset RUBYOPT RSPEC_OPTS SPEC_OPTS RSPEC_TIA_CONFIG RSPEC_TIA_FRAGMENT_PATH DATABASE_URL
  unset CI_NODE_INDEX CI_NODE_TOTAL TEST_ENV_NUMBER PARALLEL_TEST_GROUPS PARALLEL_PID_FILE
  export BUNDLE_GEMFILE="$repository/Gemfile"
  export RAILS_ENV=test FIXTURE_EAGER_LOAD=false
  bundle exec rspec --options .rspec --order defined
)
rm -rf "$workdir"
```

Set `FIXTURE_EAGER_LOAD=true` for eager loading. To collect a map, replace the
`bundle exec rspec` line with:

```sh
bundle exec ruby -I "$repository/lib" -rrspec_tia/boot -S rspec \
  --options .rspec --order defined \
  --require rspec_tia/formatter --format RspecTia::Formatter
```

The model is explicitly loaded before the suite starts in every mode. Its class
contains a validation declaration but no method body. Data resets use raw SQL so
that unrelated specs do not acquire an Account dependency merely from setup.
Each process creates its own in-memory schema; each example starts with one named
record. The application needs no network, external database, or services.

## Cases and handwritten answers

All expectation paths are relative to the copied application root. Comparisons
use sets, not execution order or map timestamps. Do not generate the expectation
files from a collected map.

| Cases | Dedicated source / behavior | Expected consumers |
| --- | --- | --- |
| M1 | `app/services/shared_value.rb` | `spec/services/first_spec.rb`, `second_spec.rb` |
| M2 | `app/services/unused_value.rb` | None, including after eager loading |
| M3/M4 | Preloaded `app/models/account.rb`; named SQL and instantiation | Both model specs with AR support; none without it |
| M5 | `context_before`, `context_after`, `nested_before`, `nested_after`, `all_before`, `all_after`, `second_group_value` services | Only `spec/hooks/context_spec.rb`; covers nested groups, aliases, and multiple top-level groups |
| M6 | `suite_before`, `suite_after` services | Every spec, discovered from files independently of the map |
| M7 | `shared_example_value` service | Both shared example consumers, never the support definition |
| M8 | Accounts template, shared navigation, cached collection item, application layout, partial layout | Accounts template/partial layout belong only to accounts; shared files belong to both request specs, including warm compiled/cache paths |
| M9 | Dedicated `tracking` partials rendered during boot, context/suite hooks, and shared examples | Boot has no consumers; context renders belong only to the hook spec; suite renders belong to all specs; shared examples belong to both runnable consumers |
| P1 | ERB template | Request spec via static mapping, even when runtime edges are removed |
| P2 | Added `future_value.rb`, absent from the baseline map | Existing `future_value_spec.rb` via naming convention |
| P3 | Changed spec | That spec itself |
| P4 | Changed `config/routes.rb` | Full run with the configured path reason |
| P5 | Shared partial or layout change | Both request specs through runtime edges, without a matching static rule |
| P6 | Newly added, unrendered accounts template | Existing request spec via the static view rule |
| V1 | Shared return value and model validation mutations | The specified assertion failures must be selected and fail again in a fresh selected run |
| V2 | Shared navigation mutation | Both request assertion failures must be selected without a matching static rule |

`expectations/mapping.yml` requires exact dependency sets for dedicated sources,
checking both missing and extra dependencies. `predictions.yml` checks the final
Predictor result separately. The template case explicitly strips runtime edges
to prove the static rule supplies the prediction.

The runner checks every mapping case in normal and eager modes with `defined`,
`rand:12`, and `rand:97` ordering. Eager mode with AR supplementation disabled runs
once and checks only the model comparison. One process supplies all applicable
mapping cases for each mode/order pair.

`spec/integration/action_view_mapping_spec.rb` additionally removes all static
rules and checks normal Rails loading, independent AR/ActionView switches, global
Rails disablement, and prediction after map dump/load/merge. Real inline and
external-file renders must preserve ordinary coverage edges without adding
non-project sources. Warm fragment and collection caches explicitly demonstrate
that nested partial notifications disappear on cache hits. The primary collection
partial remains visible. Use disabled render caching, explicit static mappings,
or full-run paths for nested dependencies hidden by cached bodies.

## Mutations and adding cases

`expectations/mutations.yml` describes three independent changes to the same clean
baseline. Each literal replacement must match exactly once. The baseline full run
must pass before its map is used. Each mutation gets a fresh copy; its full run
and selected run use fresh processes and never record a map. RSpec JSON reports
must show the exact expected assertion failures. Startup errors, syntax errors,
empty failures, hook errors, and timeouts cannot count as detection. The shared
service mutation also forbids selecting the unrelated service spec.

To add a case:

1. Add a small source and runnable spec that make the dependency understandable.
   Assign dedicated sources to hook/shared-example cases to expose contamination.
2. Write an explanation and an `exact_specs` set in `mapping.yml`. Use `all` only
   for dependencies intended for every independently discovered spec. Add
   `exact_specs_without_ar` when the case needs the supplementation comparison.
3. For selection behavior, add changed files, expected `specs`, and optional
   `full_run` / `reason` to `predictions.yml`. `added_source` / `added_content`
   describe a file created only after collecting the baseline map. `static_only`
   checks selection with a fresh map containing specs but no runtime edges.
4. For a regression mutation, add its source, unique `before` / `after` literals,
   expected `failed_specs`, and optional `forbidden_specs` to `mutations.yml`.
5. Run `bundle exec rspec spec/integration` and the full repository suite.

The runner validates that referenced source/spec paths exist. Maps must contain
exactly the independently discovered fixture specs. Integration specs explicitly
require `spec/support/rails_app_runner.rb`; the parent helper does not autoload it.

## Artifacts and diagnostics

Integration runs use `Dir.mktmpdir` and delete their copies on exit. JSON reports
and map fragments live under each copy's `tmp/run-N/`; SQLite stays in memory and
Rails logs go to the null device. Direct map collection uses the configured
`tmp/rspec_tia/fragments/` inside the copy. No generated artifacts belong in this
fixture or the gem package.

Each child has a 45-second timeout; a timed-out process group is killed and reaped.
Runner failures include mode, command, temporary root, exit status, and child
output. Mapping mismatches include case, mode, source, missing specs, and extra
specs. Assertion checks include structured results on invalid failures. Parent
mapping/parallel options and `RUBYOPT` are cleared so earlier runs cannot supply
fragments or change instrumentation.

This fixture does not claim coverage for inheritance/STI, concerns, bodyless
non-AR classes, SQL-free model operations, or failed-hook map invalidation. The
existing formatter hook/loading specs remain in place. It does not compare
alternative collectors, reproduce historical PRs, assess large-app speed, or
introduce a separate Rails version matrix.

## Local ActionView comparison

On 2026-10-26, Ruby 4.0.7 / Rails 7.2.4 on macOS, an eager-loaded run of this
fixture (17 examples in 12 spec files, defined order) was compared with
`rails.action_view` disabled and enabled. All static mappings were removed in
both runs. Each configuration generated a fresh map before independently
injecting `V2_shared_partial`; a full run supplied the failing specs for audit.
JUnit audit input was derived from those validated full-run assertion failures.

| Measurement | Disabled | Enabled |
| --- | ---: | ---: |
| Total dependency edges | 63 | 102 |
| View dependency edges | 0 | 39 |
| Map-generation process wall time, including startup | 1.256 s | 1.299 s |
| Selected specs for the shared navigation change | 0 | 2 |
| Full-run failing specs | 2 | 2 |
| Audit missed failures | 2 | 0 |

These are single local observations on a small correctness fixture, not a
performance benchmark or a large application evaluation. Regenerate and audit
maps in the consuming application to assess its additional dependencies and cost.
