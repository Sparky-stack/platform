# syntax=docker/dockerfile:1
# Ruby / Rails image: gems are compiled in a build stage, the runtime stage is
# ruby-slim without compilers, running as non-root. Builds on the target
# platform (native runner or QEMU) because native gems are arch-specific.
ARG RUBY_IMAGE=docker.io/library/ruby:4.0.9-slim@sha256:d8cb2c0714bdaba0f318af897a01d2dbde3cfa8e62d47e99cea55feb13c0e90d

FROM ${RUBY_IMAGE} AS base
WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development:test" \
    RACK_ENV=production \
    RAILS_ENV=production

FROM base AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git pkg-config libyaml-dev \
 && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock .ruby-version ./
RUN bundle install --jobs 4 \
 && rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git
COPY . .
# Rails: precompile bootsnap and assets without real secrets.
RUN if [ -f bin/rails ]; then \
      bundle exec bootsnap precompile app/ lib/ 2>/dev/null || true; \
      SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile; \
    fi

FROM base
RUN useradd --system --uid 65532 --home /app --shell /usr/sbin/nologin app
COPY --from=build --chown=65532:65532 ${BUNDLE_PATH} ${BUNDLE_PATH}
COPY --from=build --chown=65532:65532 /app /app
ARG VERSION=dev
ENV APP_VERSION=${VERSION}
USER 65532:65532
EXPOSE 3000
# Rails apps: CMD ["./bin/rails", "server", "-b", "0.0.0.0"]
CMD ["bundle", "exec", "puma", "--bind", "tcp://0.0.0.0:3000", "config.ru"]
