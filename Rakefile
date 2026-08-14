require 'bundler/gem_tasks'

require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new

require 'rubocop/rake_task'
RuboCop::RakeTask.new(:rubocop)

task default: [:spec, :rubocop]

desc "Run the end-to-end tests: real uploads across a Docker version matrix (see e2e/README.md)"
task :e2e do
  sh "./e2e/run.sh"
end
