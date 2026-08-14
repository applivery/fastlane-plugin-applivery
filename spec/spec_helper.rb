$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# This module is only used to check the environment is currently a testing env
module SpecHelper
end

require 'fastlane' # to import the Action super class
require 'fastlane/plugin/applivery' # import the actual plugin
require 'webmock/rspec' # no test is allowed to hit the network
require 'tmpdir'
require 'tempfile'
require 'open3'

Fastlane.load_actions # load other actions (in case your plugin calls other actions or shared values)

ENV['FASTLANE_SKIP_UPDATE_CHECK'] = '1'
ENV['FASTLANE_OPT_OUT_USAGE'] = '1'

module AppliveryTestHelpers
  # Runs a command without printing anything, used to set up the git fixtures.
  def sh_quiet(*args)
    output, status = Open3.capture2e(*args)
    raise "command failed: #{args.join(' ')}\n#{output}" unless status.success?
    return output
  end

  # Creates a git repository and yields inside of it.
  def in_git_repo(tag: nil, commit_after_tag: false)
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        sh_quiet("git", "init", "-q")
        sh_quiet("git", "checkout", "-q", "-b", "main")
        sh_quiet("git", "config", "user.email", "plugin@applivery.com")
        sh_quiet("git", "config", "user.name", "Applivery")
        sh_quiet("git", "config", "commit.gpgsign", "false")
        sh_quiet("git", "remote", "add", "origin", "git@github.com:applivery/example.git")
        File.write("build.gradle", "// example")
        sh_quiet("git", "add", ".")
        sh_quiet("git", "commit", "-q", "-m", "first commit")
        sh_quiet("git", "tag", tag) if tag
        if commit_after_tag
          File.write("README.md", "# example")
          sh_quiet("git", "add", ".")
          sh_quiet("git", "commit", "-q", "-m", "second commit")
        end

        yield
      end
    end
  end

  # Captures everything written to the file descriptor 2, including the output
  # of the child processes (which is where git writes its `fatal:` lines).
  def capture_stderr
    Tempfile.create('applivery-stderr') do |tmp|
      original_stderr = STDERR.dup
      begin
        STDERR.reopen(tmp.path, 'w')
        yield
        STDERR.flush
      ensure
        STDERR.reopen(original_stderr)
        original_stderr.close
      end

      File.read(tmp.path)
    end
  end
end

RSpec.configure do |config|
  config.include(AppliveryTestHelpers)

  # Every option of the action can come from an APPLIVERY_* variable, so the
  # environment of whoever runs the specs would change what they see (a tenant
  # exported in your shell moves the upload to another host, for example).
  config.before(:suite) do
    ENV.keys.grep(/\AAPPLIVERY_/).each { |name| ENV.delete(name) }
  end
end
