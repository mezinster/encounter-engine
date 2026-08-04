# syntax=docker/dockerfile:1
ARG RUBY_VERSION=3.3.12

FROM ruby:${RUBY_VERSION}-slim AS build
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential libpq-dev git && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /rails
COPY Gemfile Gemfile.lock ./
# Production needs pg; it must NOT inherit this workstation's
# `bundle config without production`.
RUN bundle config set --local without 'development test' && \
    bundle config set --local deployment 'true' && \
    bundle install && \
    rm -rf ~/.bundle /usr/local/bundle/ruby/*/cache
COPY . .

FROM ruby:${RUBY_VERSION}-slim
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libpq5 curl tzdata && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /rails
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails

# No asset precompile: this app has no asset-pipeline gem. Static files are
# served straight from public/.

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails /rails
USER rails:rails

ENV RAILS_ENV=production BUNDLE_WITHOUT="development test"
EXPOSE 3000
CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:3000"]
