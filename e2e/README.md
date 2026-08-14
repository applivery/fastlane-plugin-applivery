# End-to-end tests

The unit suite (`bundle exec rake spec`) never touches the network and always
runs on a single set of gems. These tests do the opposite: they install real
fastlane and faraday versions in Docker containers and **upload a real build to
a real Applivery app**, so the combinations users actually have are proven to
work.

They exist because both bugs fixed in 2.5.0 only appear in specific
combinations:

- [#20](https://github.com/fastlane-community/fastlane-plugin-applivery/issues/20):
  `uninitialized constant Faraday::UploadIO` with fastlane 2.238.0, the first
  release on faraday 2.
- [#18](https://github.com/fastlane-community/fastlane-plugin-applivery/issues/18):
  `fatal:` lines printed by git in repositories without tags.

## Requirements

- Docker (any engine the `docker` CLI can reach).
- An Applivery integration token of an app that accepts the build file you use.
  **Use a throwaway app**: every run adds builds to it.
- An IPA, APK or AAB somewhere on your machine. It is mounted read-only, never
  copied into the repository or into an image.

## Setup

```bash
cp e2e/config.env.example e2e/config.env
$EDITOR e2e/config.env
```

`e2e/config.env` is git-ignored and the runner refuses to start if it ever ends
up tracked. The token is passed to the containers by name (`docker run -e NAME`)
so it stays out of the process list, is never a build argument, and is redacted
from the captured output.

## Usage

```bash
./e2e/run.sh --list                      # matrix and scenarios, runs nothing
./e2e/run.sh --only latest --suite full  # one row, every scenario
./e2e/run.sh                             # the whole matrix
./e2e/run.sh --only ruby27 --no-build    # re-run without rebuilding the image
./e2e/run.sh --shell faraday1-last       # shell inside a row, same mounts
```

Output of each row is teed to `e2e/logs/<row>.log` (and `<row>.log.build` for
the image build). Exit status is non-zero if any row failed.

## The matrix

Only real compatibility boundaries are covered; anything between them retests an
identical combination. fastlane's ruby floor moved to `>= 2.7` in 2.232.0 and to
`>= 3.0` in 2.235.0, and 2.238.0 is the first release requiring `faraday ~> 2.7`.

| row | ruby | fastlane | faraday | suite | why |
|---|---|---|---|---|---|
| `latest` | 3.4 | 2.238.0 | 2.x newest | core + full | newest of everything, the configuration from #20 |
| `faraday2-min` | 3.0 | 2.238.0 | 2.7.x | core | lowest ruby for faraday 2, oldest faraday 2 accepted |
| `faraday1-last` | 3.0 | 2.237.0 | 1.10.x | core | last fastlane on faraday 1 |
| `ruby27` | 2.7 | 2.234.0 | 1.9.x | core | last fastlane supporting ruby 2.7, older faraday 1 line |
| `ruby26-oldest` | 2.6 | 2.231.x | 1.10.x | core | the floor of `required_ruby_version` in the gemspec |
| `ruby40` | 4.0 | 2.238.0 | 2.x newest | core | newest Ruby, ahead of any fastlane Ruby ceiling |

Each row prints the versions it actually resolved and **fails** if faraday is not
the major the row is meant to exercise, so a resolution surprise cannot make a
row silently meaningless.

The last row is marked as allowed to fail in `matrix.txt`: it depends on gems
that are no longer maintained for ruby 2.6, so a failure there is reported as a
warning rather than breaking the run.

## The scenarios

`core` runs in every row; the newest row runs both suites (`--suite` overrides it).

| scenario | suite | uploads | what it proves |
|---|---|---|---|
| `action_docs` | core | no | the action and every option load on this stack |
| `unit_specs` | core | no | the whole unit suite passes against this row's faraday |
| `minimal_tagged` | core | yes | upload from a tagged repo, with branch/commit/tag/remote attached |
| `untagged_quiet` | core | yes | upload from a repo with no tags and **no `fatal:` output** (#18) |
| `bad_token` | core | no | an invalid token is reported as such |
| `missing_build` | core | no | a wrong path fails before any request is sent |
| `all_params` | full | yes | every option at once, emoji/newlines in the changelog, arguments winning over env vars |
| `filter_groups` | full | yes | a group filter with a `\|` survives the multipart encoding |
| `env_vars_only` | full | yes | everything through `APPLIVERY_*`, invoked as `fastlane run applivery` |
| `plain_dir` | full | yes | upload from a directory that is not a git repository |
| `autodetect_apk` | full | yes | the build is taken from the lane context, as gradle leaves it |
| `path_with_space` | full | yes | a build path containing a space |
| `dir_as_build_path` | full | no | a directory never reaches the API |
| `empty_token` | full | no | an empty token is reported as such |
| `no_build_path` | full | no | with nothing to upload the action explains how to set it |
| `timeout_zero` | full | no | `timeout` is validated while parsing the options |
| `bad_tenant` | full | no | an unresolvable tenant is a connection error |
| `timeout_tiny` | full | no | a one second timeout suggests raising it |

Every scenario also asserts that the output never contains `fatal:`,
`uninitialized constant`, `NameError` or `undefined method`. Note that
`UploadIO` on its own is *not* forbidden: `Faraday::Multipart::FilePart` is an
alias of `Multipart::Post::UploadIO`, so a verbose request body prints it
legitimately.

Scenarios marked as optional (`filter_groups`, `timeout_tiny`)
report `WARN` instead of `FAIL`: they depend on the tenant configuration or on
the speed of the link rather than on the plugin.

## Differences between stacks worth knowing

Things the matrix surfaced that are not plugin bugs, but do change what users
see:

- **A refused token is reported differently on old stacks.** With ruby 2.6 and
  faraday 1.10 the API rejects the token and closes the connection while
  Net::HTTP is still writing the 17 MB body, so the upload dies with `EPIPE`
  (`Could not connect to Applivery: Broken pipe`) before the JSON error can be
  read. Newer stacks read the response and report `The app_token is not valid`.
  The `bad_token` and `empty_token` scenarios accept either message.
- **The API accepts files that are not builds.** Uploading a small text file
  succeeds and creates a build; the validation happens later, out of band, so
  there is no synchronous 5006 to assert.
- **The first upload of a given file takes much longer** (about three minutes
  for 17 MB) while Applivery processes it; identical re-uploads finish in about
  two seconds. That first upload alone exceeds Net::HTTP's default 60 second
  read timeout, which is exactly why the action sets one.
- **`fastlane action applivery` wraps its options table** at the terminal width,
  splitting long environment variable names across lines, so only short strings
  can be asserted on that output.

## Cost and side effects

- A full matrix run creates around **16 builds** in the app: 2 per row plus 6
  extra in the newest row, which runs both suites.
- **Notifications are disabled in every scenario** (`notify_collaborators` and
  `notify_employees` are `false`), because the defaults would email the real
  collaborators and employees of the app on every run. The defaults stay covered
  by the unit specs.
- All uploads use the same two tags, `e2e` and `e2e-matrix`, so the tag list of
  the app does not grow. The row, the ruby/fastlane/faraday versions and the run
  id go in the build name and changelog instead, e.g.
  `e2e latest all params 20260813T101500Z`.
- Builds are not deleted afterwards; prune them in the dashboard when the app
  gets noisy.
- First run downloads one base image per ruby version (about 6 GB of images in
  total). Rebuilds after a plugin change take seconds: the bundle is installed
  before the plugin source is copied, so only the last layers are rebuilt.

## Debugging a single combination

```bash
./e2e/run.sh --only faraday1-last --no-build   # just that row, from the cached image
./e2e/run.sh --shell faraday1-last             # interactive
```

Inside the shell:

```bash
ruby /e2e/scenarios.rb                                    # the whole suite
cd /work/tagged && bundle exec fastlane android minimal --verbose
bundle exec ruby -e 'require "faraday"; puts Faraday::VERSION'
bundle list
```

`/work/tagged`, `/work/untagged` and `/work/plain` are created by the runner
(the shell only has them after `ruby /e2e/scenarios.rb` has run once).

## Not part of CI

GitHub Actions only runs the unit specs and rubocop: these tests need real
credentials and produce real uploads. Run them locally before releasing, or
whenever fastlane publishes a version that changes its faraday requirement.
