# One image per matrix row. Everything that varies between rows comes in as a
# build argument, so this single definition covers ruby 2.6 + faraday 1 as well
# as ruby 3.4 + faraday 2.
#
# Build from the repository root:
#   docker build -f e2e/Dockerfile -t applivery-e2e:latest \
#     --build-arg RUBY_VERSION=3.4 --build-arg FASTLANE_REQ='= 2.238.0' .
ARG RUBY_VERSION=3.4
FROM ruby:${RUBY_VERSION}

# The full ruby images already ship git and a compiler. That matters for the
# frozen 2.6/2.7 images, whose Debian repositories are archived and would make
# `apt-get install` fail.
ARG FASTLANE_REQ=">= 2.0"
ARG FARADAY_REQ=""
ARG BUNDLER_REQ=""
ARG EXTRA_GEMS=""

# Kept as ENV so bundler sees the same requirements when the image is built and
# when the scenarios run.
ENV FASTLANE_REQ=${FASTLANE_REQ} \
    FARADAY_REQ=${FARADAY_REQ} \
    EXTRA_GEMS=${EXTRA_GEMS} \
    BUNDLE_GEMFILE=/e2e/Gemfile \
    FASTLANE_SKIP_UPDATE_CHECK=1 \
    FASTLANE_OPT_OUT_USAGE=1 \
    FASTLANE_HIDE_CHANGELOG=1 \
    FASTLANE_DISABLE_COLORS=1 \
    LANG=C.UTF-8

# The scenarios create git repositories to exercise the build metadata
RUN git config --global user.email "e2e@applivery.com" \
 && git config --global user.name "Applivery E2E" \
 && git config --global commit.gpgsign false \
 && git config --global advice.detachedHead false \
 && git config --global --add safe.directory '*'

# Old images ship an ancient resolver, which struggles with fastlane's
# dependency tree. Bundler 2.5+ requires ruby >= 3.0, hence the per-row pin.
RUN if [ -n "$BUNDLER_REQ" ]; then gem install bundler -v "$BUNDLER_REQ" --no-document; fi

# Resolution depends only on the gemspec, so install the bundle before copying
# the plugin code: editing the plugin then rebuilds in seconds.
COPY e2e/container/Gemfile /e2e/Gemfile
COPY e2e/container/fastlane/Pluginfile /e2e/fastlane/Pluginfile
COPY fastlane-plugin-applivery.gemspec /plugin/
COPY lib/fastlane/plugin/applivery/version.rb /plugin/lib/fastlane/plugin/applivery/version.rb
RUN touch /plugin/README.md /plugin/CHANGELOG.md /plugin/LICENSE \
 && bundle install --jobs 4 --retry 3

# Everything below changes often and must not invalidate the bundle
COPY lib /plugin/lib
COPY README.md CHANGELOG.md LICENSE .rspec /plugin/
COPY spec /plugin/spec
COPY e2e/container/scenarios.rb /e2e/scenarios.rb
COPY e2e/container/fastlane/Fastfile /e2e/fastlane/Fastfile

WORKDIR /work
CMD ["ruby", "/e2e/scenarios.rb"]
