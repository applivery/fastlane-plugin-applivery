describe Fastlane::Helper::AppliveryHelper do
  let(:helper) { Fastlane::Helper::AppliveryHelper }

  describe '#get_base_domain' do
    it 'defaults to applivery.io' do
      expect(helper.get_base_domain).to eq("applivery.io")
      expect(helper.get_base_domain(nil)).to eq("applivery.io")
      expect(helper.get_base_domain("   ")).to eq("applivery.io")
    end

    it 'builds the subdomain of a private tenant' do
      expect(helper.get_base_domain("mycompany")).to eq("mycompany.applivery.io")
      expect(helper.get_base_domain(" mycompany ")).to eq("mycompany.applivery.io")
    end

    it 'uses the tenant as is when it is a domain' do
      expect(helper.get_base_domain("mycompany-apps.com")).to eq("mycompany-apps.com")
    end
  end

  describe '#get_integration_number' do
    let(:env_vars) { Fastlane::Helper::AppliveryHelper::INTEGRATION_NUMBER_ENV_VARS }

    around do |example|
      backup = env_vars.map { |key| [key, ENV[key]] }
      env_vars.each { |key| ENV.delete(key) }
      example.run
      backup.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    it 'is empty when not running on a known CI' do
      expect(helper.get_integration_number).to eq("")
    end

    it 'reads the build number of the CI in use' do
      ENV['GITHUB_RUN_NUMBER'] = "42"
      expect(helper.get_integration_number).to eq("42")
    end

    it 'respects the precedence of the supported CIs' do
      ENV['GITHUB_RUN_NUMBER'] = "42"
      ENV['BUILD_NUMBER'] = "7"
      expect(helper.get_integration_number).to eq("7")
    end

    it 'ignores empty values' do
      ENV['XCS_INTEGRATION_NUMBER'] = ""
      ENV['TRAVIS_BUILD_NUMBER'] = "13"
      expect(helper.get_integration_number).to eq("13")
    end
  end

  describe '#upload_connection' do
    it 'points to the public upload endpoint' do
      connection = helper.upload_connection
      expect(connection.url_prefix.to_s).to eq("https://upload.applivery.io/")
    end

    it 'points to the upload endpoint of a private tenant' do
      expect(helper.upload_connection("mycompany").url_prefix.to_s).to eq("https://upload.mycompany.applivery.io/")
      expect(helper.upload_connection("mycompany-apps.com").url_prefix.to_s).to eq("https://upload.mycompany-apps.com/")
    end

    it 'registers the multipart middleware' do
      handlers = helper.upload_connection.builder.handlers.map(&:name)
      expect(handlers.any? { |name| name.include?("Multipart") }).to be(true)
    end

    it 'applies the given timeout to the whole request' do
      connection = helper.upload_connection(nil, 900)
      expect(connection.options.timeout).to eq(900)
      expect(connection.options.open_timeout).to eq(Fastlane::Helper::AppliveryHelper::OPEN_TIMEOUT)
    end
  end

  describe '#file_part' do
    let(:build_path) do
      path = File.join(Dir.mktmpdir, "app-release.aab")
      File.write(path, "PRETEND-AAB")
      path
    end

    it 'wraps the build in a multipart part' do
      part = helper.file_part(build_path)
      expect(part.content_type).to eq("application/octet-stream")
      expect(part.original_filename).to eq("app-release.aab")
    end

    # Faraday 1 and Faraday 2 provide the multipart classes under different
    # names, all of them are supported (see issue #18).
    it 'uses Faraday::Multipart::FilePart when available' do
      skip("Faraday::Multipart is not available") unless defined?(Faraday::Multipart::FilePart)
      expect(helper.file_part(build_path)).to be_kind_of(Faraday::Multipart::FilePart)
    end

    it 'falls back to Faraday::FilePart' do
      hide_const("Faraday::Multipart::FilePart") if defined?(Faraday::Multipart::FilePart)
      stub_const("Faraday::FilePart", Class.new do
        def initialize(path, mime_type)
          @path = path
          @mime_type = mime_type
        end
      end)

      expect(helper.file_part(build_path)).to be_kind_of(Faraday::FilePart)
    end

    it 'falls back to Faraday::UploadIO' do
      hide_const("Faraday::Multipart::FilePart") if defined?(Faraday::Multipart::FilePart)
      hide_const("Faraday::FilePart") if defined?(Faraday::FilePart)
      stub_const("Faraday::UploadIO", Class.new do
        def initialize(path, mime_type)
          @path = path
          @mime_type = mime_type
        end
      end)

      expect(helper.file_part(build_path)).to be_kind_of(Faraday::UploadIO)
    end

    it 'explains how to fix a Faraday without multipart support' do
      hide_const("Faraday::Multipart::FilePart") if defined?(Faraday::Multipart::FilePart)
      hide_const("Faraday::FilePart") if defined?(Faraday::FilePart)
      hide_const("Faraday::UploadIO") if defined?(Faraday::UploadIO)

      expect { helper.file_part(build_path) }.to raise_error(FastlaneCore::Interface::FastlaneError, /faraday-multipart/)
    end
  end

  describe '#parse_response_body' do
    it 'parses a JSON body' do
      response = double("response", body: '{"status":true}')
      expect(helper.parse_response_body(response)).to eq({ "status" => true })
    end

    it 'returns an already parsed body' do
      response = double("response", body: { "status" => true })
      expect(helper.parse_response_body(response)).to eq({ "status" => true })
    end

    it 'returns an empty hash for a body that is not JSON' do
      response = double("response", body: "<html>Bad Gateway</html>")
      expect(helper.parse_response_body(response)).to eq({})
    end

    it 'returns an empty hash for an empty body' do
      response = double("response", body: nil)
      expect(helper.parse_response_body(response)).to eq({})
    end
  end

  describe '#parse_error' do
    it 'explains an invalid build' do
      expect { helper.parse_error({ "code" => 5006 }) }.to raise_error(FastlaneCore::Interface::FastlaneError, /build path seems to be wrong/)
    end

    it 'explains an invalid app_token' do
      expect { helper.parse_error({ "code" => 4004 }) }.to raise_error(FastlaneCore::Interface::FastlaneError, /app_token is not valid/)
    end

    it 'explains an empty app_token' do
      expect { helper.parse_error({ "code" => 4002 }) }.to raise_error(FastlaneCore::Interface::FastlaneError, /app_token is empty/)
    end

    it 'includes the code and message of an unknown error' do
      expect { helper.parse_error({ "code" => 9999, "message" => "Boom" }) }.to raise_error(FastlaneCore::Interface::FastlaneError, "Upload failed. [9999]: Boom")
    end

    it 'includes the http status when there is no error object' do
      expect { helper.parse_error(nil, 502) }.to raise_error(FastlaneCore::Interface::FastlaneError, "Upload failed unexpectedly. [HTTP 502]")
    end

    it 'includes the body when the error is not an object' do
      expect { helper.parse_error("Bad Gateway", 502) }.to raise_error(FastlaneCore::Interface::FastlaneError, "Upload failed unexpectedly. [HTTP 502]: Bad Gateway")
    end
  end

  describe 'git information' do
    before do
      # fastlane does not run shell commands during tests, so the values it
      # would provide are stubbed and the rest is read from a real repository.
      allow(Fastlane::Actions).to receive(:git_branch).and_return("main")
      allow(Fastlane::Actions).to receive(:last_git_commit_message).and_return("first commit")
    end

    it 'collects the information of the current commit' do
      in_git_repo(tag: "1.2.3") do
        expect(helper.git_branch).to eq("main")
        expect(helper.git_message).to eq("first commit")
        expect(helper.git_commit).to match(/\A[0-9a-f]{7,}\z/)
        expect(helper.add_git_remote).to eq("git@github.com:applivery/example.git")
        expect(helper.git_tag).to eq("1.2.3")
      end
    end

    it 'returns no tag when the current commit is not tagged' do
      in_git_repo(tag: "1.2.3", commit_after_tag: true) do
        expect(helper.git_tag).to eq("")
      end
    end

    it 'returns no tag when the repository has no tags' do
      in_git_repo do
        expect(helper.git_tag).to eq("")
      end
    end

    # https://github.com/fastlane-community/fastlane-plugin-applivery/issues/17
    it 'does not print anything when the repository has no tags' do
      in_git_repo do
        output = capture_stderr do
          expect(helper.git_tag).to eq("")
          expect(helper.git_commit).not_to be_empty
        end

        expect(output).to eq("")
      end
    end

    it 'does not print anything outside of a git repository' do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          output = capture_stderr do
            expect(helper.git_tag).to eq("")
            expect(helper.git_commit).to eq("")
            expect(helper.add_git_remote).to eq("")
          end

          expect(output).to eq("")
        end
      end
    end

    it 'falls back to git when fastlane cannot resolve the branch' do
      allow(Fastlane::Actions).to receive(:git_branch).and_raise("not a git repository")

      in_git_repo do
        expect(helper.git_branch).to eq("main")
      end
    end

    it 'falls back to git when fastlane cannot resolve the commit message' do
      allow(Fastlane::Actions).to receive(:last_git_commit_message).and_raise("not a git repository")

      in_git_repo do
        expect(helper.git_message).to eq("first commit")
      end
    end

    it 'returns an empty branch when there is no git information at all' do
      allow(Fastlane::Actions).to receive(:git_branch).and_raise("not a git repository")
      allow(Fastlane::Actions).to receive(:last_git_commit_message).and_raise("not a git repository")

      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect(helper.git_branch).to eq("")
          expect(helper.git_message).to eq("")
        end
      end
    end
  end
end
