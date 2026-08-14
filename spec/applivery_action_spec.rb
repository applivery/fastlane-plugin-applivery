describe Fastlane::Actions::AppliveryAction do
  let(:action) { Fastlane::Actions::AppliveryAction }
  let(:upload_url) { "https://upload.applivery.io/v1/integrations/builds" }
  let(:success_body) { { status: true, data: { id: "687b0e" } }.to_json }
  let!(:build_file) do
    file = Tempfile.new(["app-release", ".aab"])
    file.write("PRETEND-AAB-CONTENT")
    file.close
    file
  end

  def config(overrides = {})
    FastlaneCore::Configuration.create(
      action.available_options,
      { app_token: "my-token", build_path: build_file.path }.merge(overrides)
    )
  end

  # Keeps the request around so the specs can check what was uploaded
  def stub_upload(url: nil, body: nil, status: 200, headers: { 'Content-Type' => 'application/json' })
    stub_request(:post, url || upload_url).to_return do |request|
      @request = request
      { status: status, body: body || success_body, headers: headers }
    end
  end

  before do
    Fastlane::Actions.lane_context.clear

    # The git information is covered by the helper specs
    allow(Fastlane::Helper::AppliveryHelper).to receive(:git_branch).and_return("main")
    allow(Fastlane::Helper::AppliveryHelper).to receive(:git_commit).and_return("abc1234")
    allow(Fastlane::Helper::AppliveryHelper).to receive(:git_message).and_return("first commit")
    allow(Fastlane::Helper::AppliveryHelper).to receive(:add_git_remote).and_return("git@github.com:applivery/example.git")
    allow(Fastlane::Helper::AppliveryHelper).to receive(:git_tag).and_return("1.2.3")
    allow(Fastlane::Helper::AppliveryHelper).to receive(:get_integration_number).and_return("42")
  end

  describe '#run' do
    it 'uploads the build and exposes the new build id' do
      stub = stub_upload

      expect(action.run(config)).to eq("687b0e")
      expect(Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::APPLIVERY_BUILD_ID]).to eq("687b0e")
      expect(stub).to have_been_requested
    end

    it 'authenticates the request with the app token' do
      stub = stub_request(:post, upload_url)
             .with(headers: { 'Authorization' => "bearer my-token", 'Accept' => "application/json" })
             .to_return(status: 200, body: success_body, headers: { 'Content-Type' => 'application/json' })

      action.run(config)
      expect(stub).to have_been_requested
    end

    it 'sends the build as a multipart file' do
      stub_upload

      action.run(config)

      expect(@request.headers['Content-Type']).to start_with("multipart/form-data; boundary=")
      expect(@request.body).to include("PRETEND-AAB-CONTENT")
      expect(@request.body).to include(%(name="build"; filename="#{File.basename(build_file.path)}"))
      expect(@request.body).to include("Content-Type: application/octet-stream")
    end

    it 'sends the build metadata' do
      stub_upload

      action.run(config(name: "RC 1.0", changelog: "Bug fixing", tags: "RC1, QA", filter: "group1,group2|group3", notify_collaborators: false))

      expect(@request.body).to include('name="versionName"')
      expect(@request.body).to include("RC 1.0")
      expect(@request.body).to include('name="changelog"')
      expect(@request.body).to include("Bug fixing")
      expect(@request.body).to include('name="tags"')
      expect(@request.body).to include("RC1, QA")
      expect(@request.body).to include('name="filter"')
      expect(@request.body).to include("group1,group2|group3")
      expect(@request.body).to include('name="notifyCollaborators"')
    end

    it 'sends the information of the deployment' do
      stub_upload

      action.run(config)

      expect(@request.body).to include('name="deployer[name]"')
      expect(@request.body).to include("fastlane")
      expect(@request.body).to include('name="deployer[info][buildNumber]"')
      expect(@request.body).to include('name="deployer[info][branch]"')
      expect(@request.body).to include("main")
      expect(@request.body).to include('name="deployer[info][commit]"')
      expect(@request.body).to include("abc1234")
      expect(@request.body).to include('name="deployer[info][commitMessage]"')
      expect(@request.body).to include('name="deployer[info][repositoryUrl]"')
      expect(@request.body).to include("git@github.com:applivery/example.git")
      expect(@request.body).to include('name="deployer[info][tag]"')
      expect(@request.body).to include("1.2.3")
      expect(@request.body).to include('name="deployer[info][triggerTimestamp]"')
    end

    it 'omits the optional values that were not given' do
      stub_upload

      action.run(config)

      expect(@request.body).not_to include('name="versionName"')
      expect(@request.body).not_to include('name="tags"')
    end

    it 'uploads to the endpoint of a private tenant' do
      stub = stub_upload(url: "https://upload.mycompany.applivery.io/v1/integrations/builds")

      action.run(config(tenant: "mycompany"))
      expect(stub).to have_been_requested
    end

    it 'uploads to a custom base domain' do
      stub = stub_upload(url: "https://upload.mycompany-apps.com/v1/integrations/builds")

      action.run(config(tenant: "mycompany-apps.com"))
      expect(stub).to have_been_requested
    end
  end

  describe 'error handling' do
    it 'fails with a readable message when the API rejects the token' do
      stub_upload(body: { status: false, error: { code: 4004, message: "Invalid token" } }.to_json)

      expect { action.run(config) }.to raise_error(FastlaneCore::Interface::FastlaneError, /app_token is not valid/)
    end

    it 'fails with the code and the message of an unknown API error' do
      stub_upload(body: { status: false, error: { code: 9999, message: "Boom" } }.to_json)

      expect { action.run(config) }.to raise_error(FastlaneCore::Interface::FastlaneError, "Upload failed. [9999]: Boom")
    end

    # The previous implementation raised `undefined local variable 'response'`
    it 'fails with the http status when the response is not JSON' do
      stub_upload(status: 502, body: "<html>Bad Gateway</html>", headers: { 'Content-Type' => 'text/html' })

      expect { action.run(config) }.to raise_error(FastlaneCore::Interface::FastlaneError, /\[HTTP 502\]/)
    end

    it 'fails before uploading when the build does not exist' do
      expect { action.run(config(build_path: "/nope/missing.ipa")) }.to raise_error(FastlaneCore::Interface::FastlaneError, %r{Build not found at '/nope/missing.ipa'})
      expect(WebMock).not_to have_requested(:post, upload_url)
    end

    it 'fails before uploading when there is no build to upload' do
      expect { action.run(config(build_path: nil)) }.to raise_error(FastlaneCore::Interface::FastlaneError, /Please set the `build_path` option/)
      expect(WebMock).not_to have_requested(:post, upload_url)
    end

    it 'suggests increasing the timeout when the upload times out' do
      connection = double("connection")
      allow(connection).to receive(:post).and_raise(Faraday::TimeoutError)
      allow(Fastlane::Helper::AppliveryHelper).to receive(:upload_connection).and_return(connection)

      expect { action.run(config(timeout: 120)) }.to raise_error(FastlaneCore::Interface::FastlaneError, /increase the `timeout` option \(currently 120 seconds\)/)
    end

    it 'explains a connection failure' do
      connection = double("connection")
      allow(connection).to receive(:post).and_raise(Faraday::ConnectionFailed.new("getaddrinfo: nodename nor servname provided"))
      allow(Fastlane::Helper::AppliveryHelper).to receive(:upload_connection).and_return(connection)

      expect { action.run(config(tenant: "mycompany")) }.to raise_error(FastlaneCore::Interface::FastlaneError, /Could not connect to Applivery.*`tenant` option \(mycompany\)/)
    end
  end

  describe '#build_path' do
    after { Fastlane::Actions.lane_context.clear }

    it 'takes the ipa generated by gym on iOS' do
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::PLATFORM_NAME] = :ios
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::IPA_OUTPUT_PATH] = "example.ipa"
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::GRADLE_AAB_OUTPUT_PATH] = "example.aab"

      expect(action.build_path).to eq("example.ipa")
    end

    it 'prefers the aab over the apk on Android' do
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::PLATFORM_NAME] = :android
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::GRADLE_AAB_OUTPUT_PATH] = "example.aab"
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::GRADLE_APK_OUTPUT_PATH] = "example.apk"

      expect(action.build_path).to eq("example.aab")
    end

    it 'takes the apk when there is no aab' do
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::PLATFORM_NAME] = :android
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::GRADLE_APK_OUTPUT_PATH] = "example.apk"

      expect(action.build_path).to eq("example.apk")
    end

    it 'takes any build available when the lane has no platform' do
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::IPA_OUTPUT_PATH] = "example.ipa"

      expect(action.build_path).to eq("example.ipa")
    end

    it 'is nil when no build was generated' do
      expect(action.build_path).to be_nil
    end
  end

  describe 'action metadata' do
    it 'keeps all the documented options available' do
      keys = action.available_options.map(&:key)
      expect(keys).to eq([:app_token, :name, :changelog, :tags, :build_path, :notify_collaborators, :notify_employees, :notify_message, :filter, :tenant, :timeout])
    end

    it 'requires the app token' do
      app_token = action.available_options.find { |option| option.key == :app_token }
      expect(app_token.optional).to be_falsey
    end

    it 'exposes the build id as a shared value' do
      expect(action.output.map(&:first)).to include('APPLIVERY_BUILD_ID')
    end

    it 'supports every platform' do
      expect(action.is_supported?(:ios)).to be(true)
      expect(action.is_supported?(:android)).to be(true)
      expect(action.is_supported?(nil)).to be(true)
    end
  end
end
