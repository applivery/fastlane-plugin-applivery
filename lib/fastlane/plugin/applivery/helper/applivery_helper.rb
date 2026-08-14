require 'faraday'
require 'json'
require 'open3'

begin
  # Faraday 2 extracted multipart support into the `faraday-multipart` gem and
  # it has to be required explicitly. Faraday 1 ships it in the core gem.
  require 'faraday/multipart'
rescue LoadError
  # Nothing else to load, Faraday 1 already provides multipart support.
end

module Fastlane
  module Helper
    class AppliveryHelper
      # class methods that you define here become available in your action
      # as `Helper::AppliveryHelper.your_method`
      #
      DEFAULT_DOMAIN = "applivery.io".freeze
      UPLOAD_MIME_TYPE = "application/octet-stream".freeze

      # Seconds we wait for the connection to be established. The upload itself
      # is limited by the `timeout` option of the action instead.
      OPEN_TIMEOUT = 60

      # Environment variables holding the build number of the current CI job,
      # ordered by precedence.
      INTEGRATION_NUMBER_ENV_VARS = [
        "XCS_INTEGRATION_NUMBER", # Xcode Server
        "BUILD_NUMBER",           # Jenkins
        "TRAVIS_BUILD_NUMBER",    # Travis CI
        "GITHUB_RUN_NUMBER",      # GitHub Actions
        "CI_PIPELINE_IID",        # GitLab CI
        "CIRCLE_BUILD_NUM",       # CircleCI
        "BITRISE_BUILD_NUMBER",   # Bitrise
        "BUILD_BUILDID"           # Azure Pipelines
      ].freeze

      def self.platform
        platform = Actions.lane_context[Actions::SharedValues::PLATFORM_NAME]
        if platform == :ios or platform.nil?
          return "ios"
        elsif platform == :android
          return "android"
        end
      end

      def self.get_base_domain(tenant = nil)
        tenant = tenant.to_s.strip
        return DEFAULT_DOMAIN if tenant.empty?
        return tenant if tenant.include?(".")
        return "#{tenant}.#{DEFAULT_DOMAIN}"
      end

      def self.get_integration_number
        INTEGRATION_NUMBER_ENV_VARS.each do |env_var|
          integration_number = ENV[env_var].to_s.strip
          return integration_number unless integration_number.empty?
        end

        return ""
      end

      ### HTTP Methods ###

      # Connection used to upload the build. Both the read and the write
      # timeouts are set from `timeout` so uploading big builds over a slow
      # network doesn't fail after Net::HTTP's default 60 seconds.
      def self.upload_connection(tenant = nil, timeout = nil)
        url = "https://upload.#{get_base_domain(tenant)}"
        UI.verbose("Applivery upload URL: #{url}")

        request_options = { open_timeout: OPEN_TIMEOUT }
        request_options[:timeout] = timeout if timeout

        Faraday.new(url: url, request: request_options) do |faraday|
          faraday.request(:multipart)
          faraday.request(:url_encoded)
          faraday.adapter(:net_http)
        end
      rescue Faraday::Error => e
        UI.user_error!("Could not prepare the upload request: #{e.message}. Please add `gem 'faraday-multipart'` to your Gemfile and run `bundle install`")
      end

      # Wraps the build in the multipart class provided by the installed Faraday
      # version: `Faraday::Multipart::FilePart` (Faraday 2 and Faraday >= 1.10),
      # `Faraday::FilePart` or the long deprecated `Faraday::UploadIO`.
      def self.file_part(path, mime_type = UPLOAD_MIME_TYPE)
        if defined?(Faraday::Multipart::FilePart)
          Faraday::Multipart::FilePart.new(path, mime_type)
        elsif defined?(Faraday::FilePart)
          Faraday::FilePart.new(path, mime_type)
        elsif defined?(Faraday::UploadIO)
          Faraday::UploadIO.new(path, mime_type)
        else
          UI.user_error!("Faraday #{Faraday::VERSION} does not provide multipart support. Please add `gem 'faraday-multipart'` to your Gemfile and run `bundle install`")
        end
      end

      # Parses the response body, which is a Hash when a JSON middleware is
      # installed in the connection and a String otherwise.
      def self.parse_response_body(response)
        body = response.body
        return body if body.kind_of?(Hash)

        parsed_body = JSON.parse(body.to_s)
        parsed_body.kind_of?(Hash) ? parsed_body : {}
      rescue JSON::ParserError
        UI.verbose("Response body is not valid JSON: #{response.body}")
        return {}
      end

      ### GIT Methods ###

      # fastlane resolves the branch from the environment of the CI when possible,
      # git is only asked when it has nothing to report.
      def self.git_branch
        branch = fastlane_git_value { Actions.git_branch }
        return branch unless branch.empty?
        return git_command("rev-parse", "--abbrev-ref", "HEAD")
      end

      def self.git_commit
        return git_command("rev-parse", "--short", "HEAD")
      end

      def self.git_message
        message = fastlane_git_value { Actions.last_git_commit_message }
        return message unless message.empty?
        return git_command("log", "-1", "--pretty=%B")
      end

      def self.add_git_remote
        return git_command("config", "--get", "remote.origin.url")
      end

      # Returns the tag pointing at HEAD, or an empty String when the current
      # commit is not tagged (or the repository has no tags at all).
      def self.git_tag
        tag = git_command("describe", "--abbrev=0", "--tags")
        return "" if tag.empty?

        tag_commit = git_command("rev-list", "-n", "1", tag)
        head_commit = git_command("rev-parse", "HEAD")
        return tag if !tag_commit.empty? && tag_commit == head_commit
        return ""
      end

      # Values that fastlane can provide itself. It raises when there is no git
      # information available, and then git is asked directly.
      def self.fastlane_git_value
        yield.to_s.strip
      rescue StandardError => e
        UI.verbose("Applivery: fastlane could not provide the git information: #{e.message}")
        return ""
      end
      private_class_method :fastlane_git_value

      # Runs a git command without leaking anything to the console. Git writes
      # to stderr when there are no tags, when the folder is not a repository,
      # etc. and those `fatal:` lines used to look like the upload had failed.
      def self.git_command(*args)
        output, status = Open3.capture2("git", *args, err: File::NULL)
        unless status.success?
          UI.verbose("Applivery: `git #{args.join(' ')}` exited with #{status.exitstatus}")
          return ""
        end

        return output.strip
      rescue StandardError => e
        UI.verbose("Applivery: `git #{args.join(' ')}` failed: #{e.message}")
        return ""
      end
      private_class_method :git_command

      # `error` is the `error` object returned by the API. Anything else (a
      # missing body, an HTML error page from a proxy, ...) ends up in the
      # generic message including the HTTP status code.
      def self.parse_error(error, status = nil)
        unless error.kind_of?(Hash)
          details = error.to_s.strip
          details = details.empty? ? "" : ": #{details}"
          UI.user_error!("Upload failed unexpectedly. [HTTP #{status || 'unknown'}]#{details}")
        end

        case error["code"].to_i
        when 5006
          UI.user_error!("Upload failed. The build path seems to be wrong or the file is invalid")
        when 4004
          UI.user_error!("The app_token is not valid. Please, go to your app settings and double-check the integration tokens")
        when 4002
          UI.user_error!("The app_token is empty. Please, go to your app Settings->Integrations to generate a token")
        else
          UI.user_error!("Upload failed. [#{error['code']}]: #{error['message']}")
        end
      end
    end
  end
end
