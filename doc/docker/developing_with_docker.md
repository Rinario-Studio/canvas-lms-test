# Using Docker for Canvas Development

_*Instructure employees should use the `inst` CLI. Go [here](./../../inst-cli/doc/docker/developing_with_docker.md) for more info.*_

You can use Docker in your development environment for a more seamless
way to get started developing Canvas.

**Note for previous Docker for Canvas development users**
If you have a `docker-compose.override.yml`, you'll need to update it to version 2 or delete it.

## Automated setup script

The easiest way to get a working development environment is to run:

```
./script/docker_dev_setup.sh
```

This will guide you through the process of building the docker images and setting up Canvas.

If you would rather do things manually, read on! And be sure to check the [Troubleshooting](#Troubleshooting) section below.

## Recommendations

By default `docker compose` will look at 2 files
- docker-compose.yml
- docker-compose.override.yml

If you do not specify your own `docker-compose.override.yml` file,
the `./script/docker_dev_setup.sh` (as well as the `./script/docker_dev_update.sh` script) will copy a working
one into the root directory for docker-compose to use.
The `docker-compose.override.yml` file is ignored by git in the `.gitignore` file, so you must provide one or run the
setup script before running docker-compose.

You may manually copy the `config/docker-compose.override.yml.example` to `docker-compose.override.yml` with the following
command: `cp config/docker-compose.override.yml.example docker-compose.override.yml`.

Keep in mind copying this manually will overwrite any existing `docker-compose.override.yml` file, whereas the setup
script will not overwrite an existing configuration.
If you need more than what the default override provides you should use a `.env` file to set your `COMPOSE_FILE` environment variable.

### Create your own local docker-compose overrides file(s)

In order to tweak your local environment (which you may want to do for any of several reasons),
you can create your own [docker-compose overrides file](https://docs.docker.com/compose/compose-file/).
To get docker-compose to pick up your file and use its settings, you'll want to set an
environment variable `COMPOSE_FILE`.  The place to do this is in a `.env` file.
Create a `docker-compose.local.<username>.yml` and add a `COMPOSE_FILE` environment variable.
This variable can then have a list of files, separated by `:`.  You need to keep the main docker-compose and docker-compose.override (generated by `./script/docker_dev_setup.sh`) otherwise everything will be ruined.

```bash
echo "COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.local.`whoami`.yml" >> .env
```

Setup your user-specific docker-compose override file as an empty file using the following command:

```bash
echo "version: '2.3'" > docker-compose.local.`whoami`.yml
```

## Getting Started
After you have [installed the dependencies](getting_docker.md). You'll need to copy
over the required configuration files.

The `docker-compose/config` directory has some config files already set up to use
the linked containers supplied by config. Only copy yamls, not the contents of new-jenkins folder.
You can just copy them to
`config/`:

```
$ cp docker-compose/config/*.yml config/
```

Now you're ready to build all of the containers. This will take a while as a lot is going on here.

- Images are downloaded and built
- Database is created and initial setup is run
- Assets are compiled

First let's get our Mutagen sidecar running.

```bash
docker compose build --pull
docker compose up --no-start web
```

Now we can install assets, create and migrate databases.

```bash
docker compose run --rm web ./script/install_assets.sh
docker compose run --rm web bundle exec rake db:create db:initial_setup
docker compose run --rm web bundle exec rake db:migrate RAILS_ENV=test
```

Now you should be able to start up and access canvas like you would any other container.
```bash
docker compose up -d
open http://canvas.docker/
```

## Normal Usage

Normally you can just start everything with `docker compose up -d` and
access Canvas at http://canvas.docker/

After pulling new code, you'll want to update all your local gems, rebuild your
docker images, pull plugin code, run migrations, and recompile assets. This can
all be done with one command:

```
./script/docker_dev_update.sh
```

Changes you're making are not showing up? See the Caveats section below.


### With VS Code

First you'll need to enable the specific debug configuration for VSCode by
adding `docker-compose/rdbg.override.yml` to the `COMPOSE_FILE` variable in the
`.env` file. Example:
```
COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose/rdbg.override.yml
```

Once you have built your container, open the folder in VSCode.
If you don't already have the Dev Containers extension installed, it will prompt you that it is a recommended extension.
Once that is installed, it should prompt you to reopen the folder in the container.
Go ahead and do so.
Debug configurations will already be set up.
You can attach to the currently running web server, or run specs for the currently active spec file.

Canvas also comes with the Ruby LSP rspec extension in development mode.

Add the following to your VS Code settings to run rspec tests via CodeLense UI elements:
```json
...
"rubyLsp.addonSettings": {
  "Ruby LSP RSpec": {
    "rspecCommand": "cd /usr/src/app && rspec"
  }
}
...
```

### Debugging

A Ruby debug server is running in development mode on the web and job containers
to allow you to remotely control any sessions where the debugger has yielded
execution. To use it, you will need to enable `REMOTE_DEBUGGING_ENABLED`.
You can easily add it by adding `docker-compose/rdbg.override.yml` to the
`COMPOSE_FILE` variable in the `.env` file. Example:
```
COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose/rdbg.override.yml
```

You can attach to the server once the container is started:

Debugging web:

```
docker compose exec web bin/rdbg --attach
```

Debugging jobs:

```
docker compose exec jobs bin/rdbg --attach
```

### Prefer pry?

Unfortunately, you can't start a pry session in a remote debug session. What
you can do instead is use `pry-remote`.

1. Add `pry-remote` to your Gemfile
2. Run `docker compose exec web bundle install` to install `pry-remote`
3. Add `binding.remote_pry` in code where you want execution to yield a pry REPL
4. Launch pry-remote and have it wait for execution to yield to you:
```
docker compose exec web pry-remote --wait
```

## Running tests

```
$ docker compose exec web bundle exec rspec spec
```

### Jest Tests

Run all Jest tests with:

```
docker compose run --rm webpack yarn test:jest
```

Or run a targeted subset of tests:

```
docker compose run --rm webpack yarn test:jest ui/features/speed_grader/react/__tests__/CommentArea.test.js
```

To run a targeted subset of tests in watch mode, use `test:jest:watch` and
specify the paths to the test files as one or more arguments, e.g.:

```
docker compose run --rm webpack yarn test:jest:watch ui/features/speed_grader/react/__tests__/CommentArea.test.js


docker compose run --rm webpack yarn test:jest:watch ui/features/course_paces/react/components/course_pace_table/__tests__/assignment_row.test.tsx
```

## Selenium

To enable Selenium: Add `docker-compose/selenium.override.yml` to your `COMPOSE_FILE` var in `.env`.

The container used to run the selenium browser is only started when spinning up
all docker-compose containers, or when specified explicitly. The selenium
container needs to be started before running any specs that require selenium.
Select a browser to run in selenium through config/selenium.yml and then ensure
that only the corresponding browser is configured in selenium.override.yml.

```sh
docker compose up -d selenium-hub
```

With the container running, you should be able to open a VNC session:

<http://127.0.0.1:7900/?autoconnect=1&resize=scale&password=secret>

Now just run your choice of selenium specs:

```sh
docker compose exec web bundle exec rspec spec/selenium/dashboard_spec.rb
```

### Capturing Rails Logs and Screenshots

When selenium specs fail, the root cause isn't always obvious from the
stdout/stderr of `rspec`. E.g. you might just see an `Uncaught Error: Internal
Server Error`. To see the actual stack trace that led to the 500 response, you
have to look at the rails logs. One way to do that is to just view
`/usr/src/app/log/test.log` after the fact, or `tail -f` it during the run.
Note that the log directory is a non-synchronized volume mount, so you need to
actually view it from inside the `web` container rather than just on your
native host.

But here's a hot tip -- you can capture the portion of the rails log that
corresponds to each failed spec, plus a screenshot of the page at the time of
the failure, by running your specs with the `spec/spec.opts` options like:

```sh
docker compose exec web bundle exec rspec --options spec/spec.opts spec/selenium/dashboard_spec.rb
```

This will produce a `log/spec_failures` directory in the container, which you
can then `docker cp` to your host to view in a browser:

```sh
docker cp "$(docker compose ps -q web | head -1)":/usr/src/app/log/spec_failures .
open -a "Google Chrome" file:///"$(pwd)"/spec_failures
```

That directory tree contains a web page per spec failure, each featuring a
colorized rails log and a browser screenshot taken at the time of the failure.

## Extra Services

### Mail Catcher
Mail Catcher is used to both send and view email in a development environment.

To enable Mail Catcher: Add `docker-compose/mailcatcher.override.yml` to your `COMPOSE_FILE` var in `.env`. Then you can `docker compose up mailcatcher`.

Email is often sent through background jobs in the jobs container. If you would like to test or preview any notifications, simply trigger the email through its normal actions, and it should immediately show up in the emulated webmail inbox available here: <http://mail.canvas.docker>

### Canvas RCE API

The Canvas RCE relies on the Canvas RCE API service.

Add `docker-compose/rce-api.override.yml` to your `COMPOSE_FILE` var in `.env`.

Set `rich-content-service` `app-host` to `"http://rce.canvas.docker:3000"` in `config/dynamic_settings.yml`.
```
rich-content-service:
  app-host: "http://rce.canvas.docker:3000"
```

### StatsD
The optional StatsD service simply intercepts UDP traffic to port 8125 and echoes it.

This is useful if you want to understand what metrics are being sent to DataDog when
the application is running in production.

To enable this service, add `docker-compose/statsd.override.yml` to your .env file

Next, stop and start any running containers (a restart is not sufficient since environment variables change).

Finally, tail the statsd service logs to see what metrics Canvas is recording: `docker compose logs -ft statsd`.

## Tips

It will likely be helpful to alias the various docker-compose commands like `docker compose run --rm web` because that can get tiring to type over and over. Here are some recommended aliases you can add to your `~/.bash_profile` and reload your Terminal.

```
alias mc='docker compose'
alias mcu='docker compose up'
alias mce='docker compose exec'
alias mcex='docker compose exec web bundle exec'
alias mcr='docker compose run --rm web'
alias mcrx='docker compose run --rm web bundle exec'
```

Now you can just run commands like `mcex rake db:migrate` or `mcr bundle install`

## Troubleshooting

### Building docker container
If you get an error about some gems requiring a newer ruby, you may have to change `2.4-xenial` to `2.5` in the `FROM` line in Dockerfile.

### Permissions
If you are having trouble running the `web` container, make sure that permissions on the directory are permissive.  You can try the owner change (less disruptive):

```
chown -R 1000:1000 canvas-lms
```

Instead of `1000`, you may need to use `9999` -- the `docker` user inside the container may have uid `9999`.

Or the permissions change (which will make Docker work, but causes the git working directory to become filthy):

```
chmod a+rwx -R canvas-lms
```

If your distro is equipped with [SELinux](https://en.wikipedia.org/wiki/Security-Enhanced_Linux),
make sure it is not interfering.

```
$ sestatus
...
Current mode:                   disabled
...

```

If so, it can be disabled temporarily with:

```
sudo setenforce 0
```

Or it can be disabled permanently by editing `/etc/selinux/config` thusly:

```
SELINUX=disabled
```

### Performance
If you are having performance or other issues with your web container
starting up, you may try adding `DISABLE_SPRING: 1` to your
`docker-compose.override.yml` file, like so:

```
web: &WEB
  environment:
    DISABLE_SPRING: 1
```

Sometimes, very poor performance (or not loading at all) can be due to webpack
problems. Running
`docker compose exec web bundle exec rake canvas:compile_assets` again, or
`docker compose exec web bundle exec rake js:webpack_development` again, may help.


### DNS
If you are getting DNS resolution errors, and you use Docker Desktop or Linux,
make sure [dory](https://github.com/FreedomBen/dory) is running:

```
dory status
```

If dory is not running, you can start it with:

```
dory up
```

Alternatively, you can use Dinghy-http-proxy or Traefik to handle DNS resolution.
