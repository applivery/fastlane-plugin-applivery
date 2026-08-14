# Fastlane Applivery plugin

[![fastlane Plugin Badge](https://rawcdn.githack.com/fastlane/fastlane/master/fastlane/assets/plugin-badge.svg)](https://rubygems.org/gems/fastlane-plugin-applivery)
[![Gem Version](https://badge.fury.io/rb/fastlane-plugin-applivery.svg)](https://badge.fury.io/rb/fastlane-plugin-applivery)

## Getting Started

This project is a [fastlane](https://github.com/fastlane/fastlane) plugin. To get started with `fastlane-plugin-applivery`, add it to your project by running:

```bash
fastlane add_plugin applivery
```

It works with Faraday 1 and Faraday 2, so any fastlane version from 2.x on is supported.

## About Applivery.com

With [Applivery.com](https://www.applivery.com) you can easily distribute your iOS and Android Apps throughout a customizable platform with no need of your users have to be registered on it.

**The main purpose of this plugin is to upload a new iOS or Android build to [Applivery.com](https://www.applivery.com).**

If you usually use Fastlane tools to automate the most common development tasks now you can start using our Fastlane Plugin to easily deploy new iOS and Android versions of your Apps to Applivery and close your development cycle: Build, Test & deploy like a pro!

This **fastlane** plugin will also help you to have more context about the build, attaching and displaying the most relevant information: Direct link to the repository (GitHub & Bitbucket), commit hash, branch, tag, etc.

## Examples

Below you'll find some basic examples about how to **build** a new iOS or Android App and automatically **deploy** it into Applivery.com

### iOS App build and deploy
Next you'll find a `lane` with two steps: `gym()` that will build the iOS App and `applivery()` that will take care about the deployment.

```ruby
lane :applivery_ios do
  gym(
    scheme: "YOUR_APP_SCHEME",        # Your App Scheme
    export_method: 'enterprise')      # Choose between: enterprise or ad-hoc`
  applivery(
    app_token: "YOUR_APP_TOKEN")      # Your Applivery App Token
end
```

### Android App build and deploy
Next you'll find a `lane` with two steps: `gradle()` that will build the Android App and `applivery()` that will take care about the deployment.

```ruby
lane :applivery_android do
  gradle(task: "assembleRelease")
  applivery(
    app_token: "YOUR_APP_TOKEN")        # Your Applivery App Token
end
```

Please check out the [example `Fastfile`](fastlane/Fastfile) to see additional examples of how to use this plugin.

## Additional Parameters
The above examples are the most simple configuration you can have but you can add additional parameters to fully customize the deployment process. Every parameter can also be set with its environment variable, which is handy on CI. They are:

| Param                    | Environment variable              | Description                          | Mandatory | Values       |
|--------------------------|-----------------------------------|--------------------------------------|-----------|--------------|
| `app_token`              | `APPLIVERY_APP_TOKEN`             | Applivery App Token                  | YES       | string -> Available in the App Settings |
| `name`                   | `APPLIVERY_BUILD_NAME`            | Applivery Build name                 | NO        | string-> i.e.: "RC 1.0"       |
| `notify_collaborators`   | `APPLIVERY_NOTIFY_COLLABORATORS`  | Notify Collaborators after deploy    | NO        | boolean -> i.e.: `true` / `false` |
| `notify_employees`       | `APPLIVERY_NOTIFY_EMPLOYEES`      | Notify Employees after deploy        | NO        | boolean -> i.e.: `true` / `false` |
| `notify_message`         | `APPLIVERY_NOTIFY_MESSAGE`        | Notification message                 | NO        | string -> i.e.: "Enjoy the new version!" |
| `changelog`              | `APPLIVERY_BUILD_CHANGELOG`       | Release notes                        | NO        | string -> i.e.: "Bug fixing"       |
| `tags`                   | `APPLIVERY_BUILD_TAGS`            | Tags to identify the build           | NO        | string -> comma separated. i.e.: `"RC1, QA"` |
| `filter`                 | `APPLIVERY_FILTER`                | List of groups that will be notified | NO        | string -> comma separated + special chars. i.e.: `"group1,group2\|group3"` =  (grupo1 AND grupo2) OR (grupo3) |
| `build_path`             | `APPLIVERY_BUILD_PATH`            | Build path to the APK/AAB/IPA file   | NO        | string -> by default it takes the IPA/APK/AAB build path |
| `tenant`                 | `APPLIVERY_TENANT`                | Private tenant name or base domain   | NO        | string -> i.e.: `mycompany` or `mycompany-apps.com`  |
| `timeout`                | `APPLIVERY_TIMEOUT`               | Upload timeout in seconds            | NO        | integer -> `600` by default |

## Shared Value
Once your build is uploaded successfully, the new generated build ID is provided by a Shared Value `APPLIVERY_BUILD_ID` that can be accessed in your lane with `lane_context[SharedValues::APPLIVERY_BUILD_ID]`. The action returns that same id, so it can also be assigned directly.

Example:

```ruby
lane :applivery_ios do
  gym(
    scheme: "YOUR_APP_SCHEME",        # Your App Scheme
    export_method: 'enterprise')      # Choose between: enterprise or ad-hoc
  build_id = applivery(
    app_token: "YOUR_APP_TOKEN")      # Your Applivery App Token
  puts "BUILD ID: #{build_id}"
  puts "BUILD ID: #{lane_context[SharedValues::APPLIVERY_BUILD_ID]}"
end
```

You could use this id to open your build information in Applivery like:

```
https://dashboard.applivery.io/{YOUR_WORKSPACE_SLUG}/apps/{YOUR_APP_SLUG}/builds?id={THIS_BUILD_ID}
```

Or to create a direct link to a specific build in your enterprise store:

```
"https://{YOUR_WORKSPACE_SLUG}.applivery.io/#{YOUR_APP_SLUG}?os={YOUR_APP_OS}&build=#{THIS_BUILD_ID}"
```

## Build information

Along with the build, the plugin sends the context of the deployment so you can identify every build in the Applivery dashboard: the build number of the CI job (Xcode Server, Jenkins, Travis CI, GitHub Actions, GitLab CI, CircleCI, Bitrise and Azure Pipelines are detected automatically), and the branch, commit, commit message, tag and repository URL of the current git checkout. All of them are optional: nothing is reported when the build is not made from a git repository.

## Run tests for this plugin

To run both the tests, and code style validation, run

```
bundle install
bundle exec rake
```

To only run the tests, or to only check the code style:

```
bundle exec rake spec
bundle exec rubocop
```

To automatically fix many of the styling issues, use

```
bundle exec rubocop -a
```

### End-to-end tests

There is also a Docker based end-to-end suite that installs real fastlane and
faraday combinations (from ruby 2.6 + faraday 1 to the newest release on faraday
2) and uploads a real build to a real Applivery app in each of them:

```
cp e2e/config.env.example e2e/config.env   # your token, tenant and build file
./e2e/run.sh --list
./e2e/run.sh
```

It needs Docker and real credentials, so it is not part of `rake` nor of CI.
See [e2e/README.md](e2e/README.md) for the version matrix, the scenarios and
what each run costs.

## Issues and Feedback

For any other issues and feedback about this plugin, please submit it to this repository or contact us at [support@applivery.com](mailto:support@applivery.com)

## Troubleshooting

If you have trouble using plugins, check out the [Plugins Troubleshooting](https://github.com/fastlane/fastlane/blob/master/fastlane/docs/PluginsTroubleshooting.md) doc in the main `fastlane` repo.

**`uninitialized constant Faraday::UploadIO`**: you are running a plugin version older than 2.5.0 with a fastlane version that uses Faraday 2 (2.238.0 and newer). Update the plugin with `bundle update fastlane-plugin-applivery`.

**Upload timeouts**: big builds on a slow network may need more time than the 600 seconds used by default. Increase it with the `timeout` option.

Run `fastlane` with `--verbose` to see the upload URL, the request body and the raw API response.

## Using `fastlane` Plugins

For more information about how the `fastlane` plugin system works, check out the [Plugins documentation](https://github.com/fastlane/fastlane/blob/master/fastlane/docs/Plugins.md).

## About `fastlane`

`fastlane` is the easiest way to automate building and releasing your iOS and Android apps. To learn more, check out [fastlane.tools](https://fastlane.tools).
