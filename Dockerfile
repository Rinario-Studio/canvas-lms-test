# GENERATED FILE, DO NOT MODIFY!
# To update this file please edit the relevant template and run the generation
# task `build/dockerfile_writer.rb --env development --compose-file docker-compose.yml,docker-compose.override.yml --in build/Dockerfile.template --out Dockerfile`

ARG RUBY=3.4

FROM instructure/ruby-passenger:$RUBY
LABEL maintainer="Instructure"

ARG RUBY
ARG POSTGRES_CLIENT=14
ENV APP_HOME /usr/src/app/
ENV RAILS_ENV development
ENV NGINX_MAX_UPLOAD_SIZE 10g
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US.UTF-8
ENV LC_CTYPE en_US.UTF-8
ENV LC_ALL en_US.UTF-8
ARG CANVAS_RAILS=7.2
ENV CANVAS_RAILS=${CANVAS_RAILS}

ENV NODE_MAJOR 20
ENV GEM_HOME /home/docker/.gem/$RUBY
ENV PATH ${APP_HOME}bin:$GEM_HOME/bin:$PATH
ENV BUNDLE_APP_CONFIG /home/docker/.bundle

WORKDIR $APP_HOME

USER root

ARG USER_ID
# This step allows docker to write files to a host-mounted volume with the correct user permissions.
# Without it, some linux distributions are unable to write at all to the host mounted volume.
RUN if [ -n "$USER_ID" ]; then usermod -u "${USER_ID}" docker \
        && chown --from=9999 docker /usr/src/nginx /usr/src/app -R; fi

RUN mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
  && curl -fsSL https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor -o /etc/apt/keyrings/yarn.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/yarn.gpg] https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list \
  && printf 'path-exclude /usr/share/doc/*\npath-exclude /usr/share/man/*' > /etc/dpkg/dpkg.cfg.d/01_nodoc \
  && echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
  && curl -sS https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
  && add-apt-repository ppa:git-core/ppa -ny \
  && apt-get update -qq \
  && apt-get install -qqy --no-install-recommends \
       nodejs \
       libxmlsec1-dev \
       python3-lxml \
       python-is-python3 \
       libicu-dev \
       libidn11-dev \
       parallel \
       postgresql-client-$POSTGRES_CLIENT \
       unzip \
       pbzip2 \
       fontforge \
       git \
       build-essential \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /home/docker/.gem/ruby/$RUBY_MAJOR.0

RUN gem install bundler --no-document -v 2.5.10 \
  && find $GEM_HOME ! -user docker | xargs chown docker:docker
RUN npm install -g npm@9.8.1 && npm cache clean --force

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable && corepack prepare yarn@1.19.1 --activate

USER docker

RUN set -eux; \
  mkdir -p \
    .yardoc \
    app/stylesheets/brandable_css_brands \
    app/views/info \
    config/locales/generated \
    log \
    node_modules \
    packages/js-utils/es \
    packages/js-utils/lib \
    packages/js-utils/node_modules \
    pacts \
    public/dist \
    public/doc/api \
    public/javascripts/translations \
    reports \
    tmp \
    /home/docker/.bundle/ \
    /home/docker/.cache/yarn \
    /home/docker/.gem/
