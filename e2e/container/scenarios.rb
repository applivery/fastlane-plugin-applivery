# End-to-end scenario runner, executed inside the container by e2e/run.sh.
#
# It prepares a few working directories (a git repository with a tag, one
# without tags and a plain folder), runs every scenario of the selected suite
# with the real plugin against the real Applivery API, and checks the exit
# status and the output of each one.
#
# Plain ruby on purpose: it has to run on ruby 2.6 as well as on 3.4.
require 'open3'
require 'fileutils'

ROW = (ENV['E2E_ROW'].to_s.empty? ? 'local' : ENV['E2E_ROW'])
SUITE = (ENV['E2E_SUITE'].to_s.empty? ? 'core' : ENV['E2E_SUITE']).downcase
RUN_ID = ENV['E2E_RUN_ID'].to_s
BUILD_PATH = (ENV['E2E_BUILD_PATH'].to_s.empty? ? '/build.apk' : ENV['E2E_BUILD_PATH'])
EXPECT_FARADAY = ENV['E2E_EXPECT_FARADAY'].to_s
TENANT = ENV['APPLIVERY_TENANT'].to_s
TOKEN = ENV['APPLIVERY_APP_TOKEN'].to_s
SCENARIO_TIMEOUT = (ENV['E2E_SCENARIO_TIMEOUT'].to_s.empty? ? '600' : ENV['E2E_SCENARIO_TIMEOUT'])

FASTFILE = '/e2e/fastlane/Fastfile'.freeze
PLUGIN_DIR = '/plugin'.freeze
WORKSPACES = {
  'tagged' => '/work/tagged',
  'untagged' => '/work/untagged',
  'plain' => '/work/plain'
}.freeze
TAG = 'v1.2.3'.freeze
BRANCH = 'main'.freeze
REMOTE = 'git@github.com:applivery/e2e-example.git'.freeze
SPACED_BUILD = '/builds/with space.apk'.freeze

# Output that must never appear, whatever the scenario does:
#   fatal:                  git leaking to the console (issue #18)
#   uninitialized constant  a missing constant, e.g. Faraday::UploadIO (issue #20)
# Note `UploadIO` on its own is NOT forbidden: Faraday::Multipart::FilePart is an
# alias of Multipart::Post::UploadIO, so the verbose request body prints it.
FORBIDDEN = ['fatal:', 'uninitialized constant', 'NameError', 'undefined method'].freeze

# Assertions on the request body printed by --verbose. Hash#inspect changed in
# ruby 3.4 ({:a=>1} became {a: 1}), so both spellings of a key are matched.
def body_string(key, value)
  /#{Regexp.escape(key)}(?:=>|: )#{Regexp.escape(value.inspect)}/
end

# Same, for values that are not strings (booleans, numbers)
def body_raw(key, value)
  /#{Regexp.escape(key)}(?:=>|: )#{Regexp.escape(value)}/
end

# Assertions on the response, i.e. on what Applivery actually stored. String
# keys print the same way on every ruby version.
def response_key(key, value)
  /"#{Regexp.escape(key)}"\s*=>\s*#{Regexp.escape(value.inspect)}/
end

def redact(text)
  return text if TOKEN.empty?
  text.gsub(TOKEN, '[REDACTED]')
end

def sh!(dir, *cmd)
  output, status = Open3.capture2e(*cmd, chdir: dir)
  raise "setup command failed: #{cmd.join(' ')}\n#{output}" unless status.success?
  output
end

def capture(dir, *cmd)
  sh!(dir, *cmd).strip
end

def setup_workspaces
  WORKSPACES.each_value do |dir|
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(File.join(dir, 'fastlane'))
    FileUtils.cp(FASTFILE, File.join(dir, 'fastlane', 'Fastfile'))
  end

  [['tagged', true], ['untagged', false]].each do |name, with_tag|
    dir = WORKSPACES[name]
    sh!(dir, 'git', 'init', '-q')
    sh!(dir, 'git', 'checkout', '-q', '-b', BRANCH)
    sh!(dir, 'git', 'remote', 'add', 'origin', REMOTE)
    File.write(File.join(dir, 'build.gradle'), "// end-to-end test\n")
    sh!(dir, 'git', 'add', '.')
    sh!(dir, 'git', 'commit', '-q', '-m', 'first commit')
    sh!(dir, 'git', 'tag', TAG) if with_tag
  end
end

PROBE = <<-'RUBY'.freeze
  require "faraday"
  begin
    require "faraday/multipart"
  rescue LoadError
  end
  require "fastlane/version"
  require "fastlane/plugin/applivery/version"

  # Same decision the helper makes when attaching the build
  file_part = if defined?(Faraday::Multipart::FilePart)
                "Faraday::Multipart::FilePart"
              elsif defined?(Faraday::FilePart)
                "Faraday::FilePart"
              elsif defined?(Faraday::UploadIO)
                "Faraday::UploadIO"
              else
                "none"
              end
  multipart = Gem.loaded_specs["faraday-multipart"]
  plugin = Gem.loaded_specs["fastlane-plugin-applivery"]
  puts [
    "ruby=#{RUBY_VERSION}",
    "fastlane=#{Fastlane::VERSION}",
    "faraday=#{Faraday::VERSION}",
    "faraday-multipart=#{multipart ? multipart.version : 'n/a'}",
    "plugin=#{Fastlane::Applivery::VERSION}",
    "plugin_path=#{plugin ? plugin.full_gem_path : 'n/a'}",
    "file_part=#{file_part}"
  ].join(" ")
RUBY

def probe_environment
  output, status = Open3.capture2e('bundle', 'exec', 'ruby', '-e', PROBE, chdir: '/e2e')
  unless status.success?
    puts redact(output)
    return nil
  end

  output.lines.map(&:strip).reject(&:empty?).last
end

def scenarios(head_short)
  upload_ok = ['Build uploaded successfully', 'E2E_BUILD_ID=']
  tenant_host = TENANT.empty? ? 'applivery.io' : TENANT

  [
    # ---------------- core: runs in every row of the matrix ----------------
    {
      'name' => 'action_docs',
      'suite' => 'core',
      'workspace' => 'tagged',
      'why' => 'the action and all of its options load on this stack',
      'cmd' => %w[bundle exec fastlane action applivery],
      'expect' => 'success',
      # The options table wraps long values across lines, so only short strings
      # can be asserted here (600 is the default of the timeout option).
      'includes' => ['applivery Options', 'app_token', 'build_path', 'timeout', '600']
    },
    {
      'name' => 'unit_specs',
      'suite' => 'core',
      'workspace' => 'plugin',
      'why' => 'the 58 unit examples, run against the faraday of this row',
      'cmd' => %w[bundle exec rspec --no-color],
      'expect' => 'success',
      'includes' => [/\d+ examples?, 0 failures/]
    },
    {
      'name' => 'minimal_tagged',
      'suite' => 'core',
      'workspace' => 'tagged',
      'uploads' => true,
      'why' => 'uploads with the minimum configuration and reports the git metadata',
      'cmd' => %w[bundle exec fastlane android minimal --verbose],
      'expect' => 'success',
      'includes' => upload_ok + [
        %r{Applivery upload URL: https://upload\.#{Regexp.escape(tenant_host)}},
        # what the plugin sent...
        body_string('tag', TAG),
        body_string('branch', BRANCH),
        body_string('commit', head_short),
        body_string('repositoryUrl', REMOTE),
        # ...and what Applivery stored
        response_key('tag', TAG),
        response_key('branch', BRANCH),
        response_key('commit', head_short),
        response_key('repositoryUrl', REMOTE)
      ]
    },
    {
      'name' => 'untagged_quiet',
      'suite' => 'core',
      'workspace' => 'untagged',
      'uploads' => true,
      'why' => 'a repository without tags must upload without printing git errors (issue #18)',
      'cmd' => %w[bundle exec fastlane android minimal --verbose],
      'expect' => 'success',
      'includes' => upload_ok + [body_string('tag', ''), body_string('branch', BRANCH)]
    },
    {
      'name' => 'bad_token',
      'suite' => 'core',
      'workspace' => 'tagged',
      'why' => 'an invalid token must be reported as such',
      'cmd' => %w[bundle exec fastlane android bad_token],
      'expect' => 'failure',
      # On old stacks (ruby 2.6 + faraday 1.10) the API rejects the token and
      # closes the connection while Net::HTTP is still writing the body, so the
      # upload fails with EPIPE before the JSON error can be read. Either
      # message is a correct diagnosis of a refused upload.
      'includes' => [/The app_token is not valid|Could not connect to Applivery/]
    },
    {
      'name' => 'missing_build',
      'suite' => 'core',
      'workspace' => 'tagged',
      'why' => 'a wrong build path must fail before any request is sent',
      'cmd' => %w[bundle exec fastlane android missing_build],
      'expect' => 'failure',
      'includes' => ["Build not found at '/nope/missing.apk'"],
      'excludes' => ['Uploading to Applivery']
    },

    # ---------------- full: only in the newest row ----------------
    {
      'name' => 'all_params',
      'suite' => 'full',
      'workspace' => 'tagged',
      'uploads' => true,
      'why' => 'every option at once, a changelog with emoji and newlines, and arguments winning over the environment',
      'cmd' => %w[bundle exec fastlane android all_params --verbose],
      # The lane passes `name:` explicitly, so the argument must win
      'env' => { 'APPLIVERY_BUILD_NAME' => 'name-from-the-environment' },
      'expect' => 'success',
      'includes' => upload_ok + [
        /versionName(?:=>|: )"e2e /,
        body_raw('notifyCollaborators', 'false'),
        body_raw('notifyEmployees', 'false'),
        /notifyMessage(?:=>|: )"End-to-end test/,
        '🚀',
        'acentuación'
      ],
      'excludes' => ['name-from-the-environment']
    },
    {
      'name' => 'filter_groups',
      'suite' => 'full',
      'workspace' => 'tagged',
      'uploads' => true,
      'optional' => true,
      'why' => 'the group filter travels intact, pipe included (needs those groups in the tenant)',
      'cmd' => %w[bundle exec fastlane android filter_groups --verbose],
      'expect' => 'success',
      'includes' => upload_ok + [/filter(?:=>|: )"[^"]*\|/]
    },
    {
      'name' => 'env_vars_only',
      'suite' => 'full',
      'workspace' => 'tagged',
      'uploads' => true,
      'why' => 'every input through APPLIVERY_* variables, invoked without a lane',
      'cmd' => %w[bundle exec fastlane run applivery],
      'env' => {
        'APPLIVERY_BUILD_PATH' => BUILD_PATH,
        'APPLIVERY_BUILD_NAME' => "e2e #{ROW} env vars #{RUN_ID}".strip,
        'APPLIVERY_BUILD_CHANGELOG' => "End-to-end test: env_vars_only\nrow: #{ROW}",
        'APPLIVERY_BUILD_TAGS' => 'e2e,e2e-matrix',
        'APPLIVERY_NOTIFY_COLLABORATORS' => 'false',
        'APPLIVERY_NOTIFY_EMPLOYEES' => 'false',
        'APPLIVERY_NOTIFY_MESSAGE' => 'End-to-end test, please ignore',
        'APPLIVERY_TIMEOUT' => '900'
      },
      'expect' => 'success',
      'includes' => ['Build uploaded successfully']
    },
    {
      'name' => 'plain_dir',
      'suite' => 'full',
      'workspace' => 'plain',
      'uploads' => true,
      'why' => 'uploading from a folder that is not a git repository reports no metadata and no errors',
      'cmd' => %w[bundle exec fastlane android minimal --verbose],
      'expect' => 'success',
      'includes' => upload_ok + [body_string('branch', ''), body_string('commit', ''), body_string('tag', '')]
    },
    {
      'name' => 'autodetect_apk',
      'suite' => 'full',
      'workspace' => 'tagged',
      'uploads' => true,
      'why' => 'the build is taken from the lane context when build_path is not given',
      'cmd' => %w[bundle exec fastlane android autodetect --verbose],
      'expect' => 'success',
      'includes' => upload_ok
    },
    {
      'name' => 'path_with_space',
      'suite' => 'full',
      'workspace' => 'tagged',
      'uploads' => true,
      'requires_file' => SPACED_BUILD,
      'why' => 'a build path containing a space is uploaded like any other',
      'cmd' => %w[bundle exec fastlane android minimal --verbose],
      'env' => { 'E2E_BUILD_PATH' => SPACED_BUILD },
      'expect' => 'success',
      'includes' => upload_ok + ['with space.apk']
    },
    {
      'name' => 'dir_as_build_path',
      'suite' => 'full',
      'workspace' => 'tagged',
      'why' => 'a directory is not a build and never reaches the API',
      'cmd' => %w[bundle exec fastlane android minimal],
      'env' => { 'E2E_BUILD_PATH' => '/work' },
      'expect' => 'failure',
      'includes' => ["Build not found at '/work'"],
      'excludes' => ['Uploading to Applivery']
    },
    {
      'name' => 'empty_token',
      'suite' => 'full',
      'workspace' => 'tagged',
      'why' => 'an empty token must be reported as such',
      'cmd' => %w[bundle exec fastlane android empty_token],
      'expect' => 'failure',
      # See bad_token: old stacks report the refused upload as a broken pipe
      'includes' => [/The app_token is empty|Could not connect to Applivery/]
    },
    {
      'name' => 'no_build_path',
      'suite' => 'full',
      'workspace' => 'plain',
      'why' => 'with nothing to upload the action explains how to set the build',
      'cmd' => %w[bundle exec fastlane android no_build_path],
      'expect' => 'failure',
      'includes' => ['Please set the `build_path` option'],
      'excludes' => ['Uploading to Applivery']
    },
    {
      'name' => 'timeout_zero',
      'suite' => 'full',
      'workspace' => 'tagged',
      'why' => 'the timeout option is validated while parsing the options',
      'cmd' => %w[bundle exec fastlane android timeout_zero],
      'expect' => 'failure',
      'includes' => ['`timeout` must be greater than 0'],
      'excludes' => ['Uploading to Applivery']
    },
    {
      'name' => 'bad_tenant',
      'suite' => 'full',
      'workspace' => 'tagged',
      'why' => 'an unreachable tenant is reported as a connection problem',
      'cmd' => %w[bundle exec fastlane android bad_tenant],
      'expect' => 'failure',
      'includes' => ['Could not connect to Applivery', 'upload-test.applivery-e2e.invalid']
    },
    {
      'name' => 'timeout_tiny',
      'suite' => 'full',
      'workspace' => 'tagged',
      'optional' => true,
      'why' => 'a one second timeout is reported with the option to raise it (skipped on a very fast link)',
      'cmd' => %w[bundle exec fastlane android timeout_tiny],
      'expect' => 'failure',
      'includes' => ['Timed out while uploading', 'currently 1 seconds']
    }
  ]
end

def selected(all)
  return all if SUITE == 'all'
  all.select { |scenario| scenario['suite'] == SUITE }
end

def command_for(scenario)
  cmd = scenario['cmd']
  return cmd unless File.executable?('/usr/bin/timeout')
  ['/usr/bin/timeout', SCENARIO_TIMEOUT] + cmd
end

def directory_for(scenario)
  return PLUGIN_DIR if scenario['workspace'] == 'plugin'
  WORKSPACES[scenario['workspace']]
end

def matches?(pattern, output)
  pattern.kind_of?(Regexp) ? !(output =~ pattern).nil? : output.include?(pattern)
end

def check(scenario, output, status)
  problems = []

  if scenario['expect'] == 'success'
    problems << "expected a successful run, exited with #{status.exitstatus}" unless status.success?
  elsif status.success?
    problems << 'expected a failure, but the run succeeded'
  end

  Array(scenario['includes']).each do |pattern|
    problems << "missing from the output: #{pattern.inspect}" unless matches?(pattern, output)
  end

  (Array(scenario['excludes']) + FORBIDDEN).each do |pattern|
    problems << "should not be in the output: #{pattern.inspect}" if matches?(pattern, output)
  end

  problems
end

### Run ###############################################################

puts '=' * 78
puts 'Applivery plugin end-to-end tests'
puts "row: #{ROW}   suite: #{SUITE}   run: #{RUN_ID}"

env_line = probe_environment
if env_line.nil?
  puts 'FATAL: could not resolve the bundle, see the output above'
  exit(1)
end
puts "env: #{env_line}"

if !EXPECT_FARADAY.empty? && env_line !~ /faraday=#{Regexp.escape(EXPECT_FARADAY)}\./
  puts "FATAL: this row must run against faraday #{EXPECT_FARADAY}.x, the bundle resolved something else"
  exit(1)
end

unless File.file?(BUILD_PATH)
  puts "FATAL: the build to upload is not mounted at #{BUILD_PATH}"
  exit(1)
end
puts "build: #{BUILD_PATH} (#{File.size(BUILD_PATH)} bytes)"
puts '=' * 78

setup_workspaces
head_short = capture(WORKSPACES['tagged'], 'git', 'rev-parse', '--short', 'HEAD')

results = []
build_ids = []
uploads = 0

selected(scenarios(head_short)).each do |scenario|
  print "  #{scenario['name'].ljust(16)} "
  $stdout.flush

  if scenario['requires_file'] && !File.file?(scenario['requires_file'])
    puts "SKIP (#{scenario['requires_file']} is not mounted)"
    results << { 'name' => scenario['name'], 'state' => 'SKIP' }
    next
  end

  started = Time.now
  output, status = Open3.capture2e(scenario['env'] || {}, *command_for(scenario), chdir: directory_for(scenario))
  seconds = (Time.now - started).round(1)
  output = redact(output)

  ids = output.scan(/E2E_BUILD_ID=(\S+)/).flatten
  build_ids.concat(ids)
  uploads += 1 if scenario['uploads']

  problems = check(scenario, output, status)
  state = if problems.empty?
            'PASS'
          elsif scenario['optional']
            'WARN'
          else
            'FAIL'
          end

  puts "#{state} (#{seconds}s)#{ids.empty? ? '' : " build=#{ids.join(',')}"}"
  problems.each { |problem| puts "      - #{problem}" }

  unless problems.empty?
    puts "      --- output of #{scenario['name']} ---"
    output.each_line { |line| puts "      #{line.rstrip}" }
    puts '      --- end of output ---'
  end

  results << { 'name' => scenario['name'], 'state' => state, 'seconds' => seconds }
end

puts '=' * 78
failed = results.select { |result| result['state'] == 'FAIL' }
warned = results.select { |result| result['state'] == 'WARN' }
skipped = results.select { |result| result['state'] == 'SKIP' }
passed = results.size - failed.size - warned.size - skipped.size
puts "row #{ROW}: #{passed} passed, #{warned.size} warned, #{skipped.size} skipped, #{failed.size} failed"
puts "uploads attempted: #{uploads}   builds created: #{build_ids.size}#{build_ids.empty? ? '' : " (#{build_ids.join(', ')})"}"
puts "failed: #{failed.map { |result| result['name'] }.join(', ')}" unless failed.empty?
puts "warned: #{warned.map { |result| result['name'] }.join(', ')}" unless warned.empty?
puts '=' * 78

exit(failed.empty? ? 0 : 1)
