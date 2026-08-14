lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'fastlane/plugin/applivery/version'

Gem::Specification.new do |spec|
  spec.name          = 'fastlane-plugin-applivery'
  spec.version       = Fastlane::Applivery::VERSION
  spec.authors       = ["Applivery"]
  spec.email         = ["info@applivery.com"]

  spec.summary       = "Upload new build to Applivery"
  spec.homepage      = "https://github.com/fastlane-community/fastlane-plugin-applivery"
  spec.license       = "MIT"

  spec.files         = Dir["lib/**/*"] + %w[README.md CHANGELOG.md LICENSE]
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 2.6'

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/master/CHANGELOG.md",
    'bug_tracker_uri' => "#{spec.homepage}/issues"
  }

  # The build is uploaded with a multipart request. Faraday 2 moved multipart
  # support to its own gem, Faraday 1 has it built in.
  spec.add_dependency 'faraday', '>= 1.0', '< 3.0'
  spec.add_dependency 'faraday-multipart', '>= 1.0', '< 2.0'

  spec.add_development_dependency 'bundler', '~> 2.0'
  spec.add_development_dependency 'fastlane', '~> 2.0'
  spec.add_development_dependency 'pry', '~> 0.14'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'rubocop', '~> 1.50.2'
  spec.add_development_dependency 'webmock', '~> 3.0'
end
