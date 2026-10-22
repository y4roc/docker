# Matomo (formerly Piwik)

[![GitHub CI build status badge](https://github.com/matomo-org/docker/workflows/GitHub%20CI/badge.svg)](https://github.com/matomo-org/docker/actions?query=workflow%3A%22GitHub+CI%22)
[![Docker Pulls](https://img.shields.io/docker/pulls/library/matomo)](https://hub.docker.com/_/matomo)
[![Docker Image Version](https://img.shields.io/docker/v/library/matomo?sort=semver&logo=matomo&label=Matomo)](https://hub.docker.com/_/matomo/tags)

<img align="right" width="300px" src="https://matomo.org/wp-content/themes/website-child/assets/img/media/matomo.png" alt="Matomo logo"></img>
[Matomo](https://matomo.org/) (formerly Piwik) is the leading open-source analytics platform that gives you more than just powerful analytics:

- Free open-source software
- 100% data ownership
- User privacy protection
- User-centric insights
- Customisable and extensible

# How to use this image

## Building

The [`Dockerfile`](Dockerfile) builds a ready-to-run image from the official, GPG-verified Matomo release:

```bash
docker build -t matomo .                                            # Apache with mod_php (default)
docker build --build-arg VARIANT=fpm -t matomo:fpm .                # PHP-FPM on Debian
docker build --build-arg VARIANT=fpm-alpine -t matomo:fpm-alpine .  # PHP-FPM on Alpine
docker build --target web -t matomo:web .                           # nginx for the fpm variants
```

Build arguments:

- `VARIANT`: `apache` (default), `fpm` or `fpm-alpine`
- `MATOMO_VERSION`: the Matomo release to build, defaults to the one in the `Dockerfile`
- `PHP_VERSION`: the version of the [`php`](https://hub.docker.com/_/php) base image, defaults to `8.4`

## Running

```bash
docker network create matomo
docker run -d --network matomo --name db -e MARIADB_RANDOM_ROOT_PASSWORD=1 -e MARIADB_DATABASE=matomo -e MARIADB_USER=matomo -e MARIADB_PASSWORD=secret mariadb:lts
docker run -d --network matomo -p 8080:80 -v matomo:/var/lib/matomo matomo
```

The [`.examples`](.examples) folder has complete set-ups with Docker Compose ([Apache](.examples/apache/compose.yml), [nginx with PHP-FPM](.examples/nginx/compose.yml)) and [Helm](.examples/helm). The Compose files build the images themselves: `docker compose -f .examples/apache/compose.yml up --build`.

## Persistent data

Matomo's code is part of the image and read-only (`/var/www/html`, don't mount anything there). Everything Matomo writes lives in `/var/lib/matomo`, which should be a volume:

| Path in `/var/lib/matomo` | Content |
|---|---|
| `config/config.ini.php` | Matomo's configuration, written by the installer |
| `config/config.php` | created by the image, loads the settings that point Matomo to the paths below |
| `tmp/` | caches, generated assets, logs |
| `misc/` | GeoIP databases |
| `public/plugins/` | plugins installed from the Marketplace |
| `public/js/` | Tag Manager containers, served as `/js/container_*.js` |
| `public/misc/user/` | custom logos and favicons |
| `public/matomo.js`, `public/piwik.js` | the JavaScript tracker, which Matomo extends with the code of plugins |

`/var/www/html/public` links to `/var/lib/matomo/public`. If you need your own [dependency injection settings](https://developer.matomo.org/guides/dependency-injection) in `config/config.php`, merge them with the ones of the image:

```php
<?php
return array_merge(require '/usr/local/share/matomo/config.php', [
    // your definitions
]);
```

The entrypoint creates what is missing in `/var/lib/matomo` and, when it runs as root, hands it over to `www-data` (or to `APACHE_RUN_USER`/`APACHE_RUN_GROUP`). With `--user`, the volume has to be writable by that user.

## Matomo Installation

Once you're up and running, you'll arrive at the configuration wizard page. If you're using the compose file, at the `Database Setup` step, please enter the following:

- Database Server: `db`
- Login: MYSQL_USER
- Password: MYSQL_PASSWORD
- Database Name: MYSQL_DATABASE

And leave the rest as default.

Then you can continue the installation with the super user.

The following environment variables are also honored for configuring your Matomo instance:

- `MATOMO_DATABASE_HOST`
- `MATOMO_DATABASE_ADAPTER`
- `MATOMO_DATABASE_TABLES_PREFIX`
- `MATOMO_DATABASE_USERNAME`
- `MATOMO_DATABASE_PASSWORD`
- `MATOMO_DATABASE_DBNAME`

`MATOMO_DATABASE_HOST`, `_USERNAME`, `_PASSWORD` and `_DBNAME` can also be read from a file (for Docker secrets) by appending `_FILE` to their name, e.g. `MATOMO_DATABASE_PASSWORD_FILE=/run/secrets/db-password`.

The PHP memory limit can be configured with the following environment variable:

- `PHP_MEMORY_LIMIT` (default: `256M`)

## Console

Run Matomo's console as the owner of the files, otherwise the files it creates belong to root:

```bash
docker compose exec --user www-data app php console core:archive --url=https://matomo.example.org
```

Use `console core:archive` for [automatic archiving](https://matomo.org/faq/on-premise/how-to-set-up-auto-archiving-of-your-reports/); the older `misc/cron/archive.php` doesn't know about `/var/lib/matomo`.

## Plugins

Plugins installed from the Marketplace end up in `/var/lib/matomo/public/plugins` and survive new images. Matomo serves their files from `/public/plugins/`; requests for `/plugins/<name>/…` are passed on there too when the plugin isn't part of the image.

## Upgrading

To upgrade, build (or pull) an image with a newer `MATOMO_VERSION` and start it with the same volume. Back up your database first.

On the first start of a new version, the entrypoint runs `console core:update` (the database upgrade) and `console custom-matomo-js:update` (rebuilds the JavaScript tracker from the new code) and notes the version in `/var/lib/matomo/.matomo-version`. On large installations the database upgrade can take a long time, and the container only starts serving once it is done. If several containers share the volume, one of them upgrades while the others wait. If the upgrade fails (e.g. the database isn't reachable yet), the error is logged, the container starts anyway, and the next start tries again.

Set `MATOMO_AUTO_UPGRADE=0` to upgrade yourself; the entrypoint then only logs a warning.

The one-click update in Matomo's user interface can't work with read-only code, Matomo will tell you so if you try it.

## The fpm variants and the web image

The fpm variants only run PHP, so they need a web server in front of them that has the static files. `docker build --target web` builds an nginx image with the same Matomo files and the configuration from [`nginx.conf`](nginx.conf). Give it the data volume (read-only is enough), because Marketplace plugins, Tag Manager containers and the JavaScript tracker live there, and tell it where PHP-FPM listens:

- `MATOMO_FPM_ADDRESS` (default: `app:9000`)

If you use your own web server instead, it needs the files of `/var/www/html` and the data volume at `/var/lib/matomo`, and it has to pass requests for `/js/…` and `/plugins/…` that don't exist in the code on to `/public/…` (see `nginx.conf`).

## Migrating from older images

Older images kept Matomo's code *and* data in a volume on `/var/www/html` and copied Matomo into it on start. This image refuses to start when it finds such a volume there, because it would run the old code. To move your data to a volume on `/var/lib/matomo` (here: from `matomo` to `matomo-data`):

1. Stop Matomo and back up your database and the old volume.
2. Copy the data with the new image:

   ```bash
   docker run --rm --entrypoint sh -v matomo:/old:ro -v matomo-data:/var/lib/matomo matomo -c '
     set -e
     cd /var/lib/matomo
     mkdir -p config misc public/js public/misc public/plugins
     for file in /old/config/*.ini.php; do
       [ "$(basename "$file")" = global.ini.php ] || cp -a "$file" config/
     done
     cp -a /old/misc/user public/misc/
     cp -a /old/misc/*.mmdb misc/ 2> /dev/null || true
     cp -a /old/js/container_*.js public/js/ 2> /dev/null || true
     # plugins that are not part of Matomo, e.g. from the Marketplace
     for plugin in /old/plugins/*/; do
       [ -d "/var/www/html/plugins/$(basename "$plugin")" ] || cp -a "$plugin" public/plugins/
     done
   '
   ```

   If you had your own `config/config.php`, merge it as shown under [Persistent data](#persistent-data).
3. Mount `matomo-data` on `/var/lib/matomo` instead of `matomo` on `/var/www/html` (with nginx, switch to the web image, see the [example](.examples/nginx/compose.yml)) and start Matomo. The entrypoint adjusts the file owners and upgrades the database if the version changed.
4. Remove the old volume once everything works.

## Log import

The [log import script](https://matomo.org/faq/log-analytics-tool/) is part of the image. Copy it out and run it with Python, e.g. with the nginx example (its network is `nginx_default`):

```bash
docker compose cp app:/var/www/html/misc/log-analytics ./log-analytics
docker run --rm --network nginx_default -v ./log-analytics:/log-analytics:ro -v /var/log/nginx:/logs:ro python:3-alpine \
  python /log-analytics/import_logs.py --url=http://web --login=yourlogin --password=yourpassword --idsite=1 --recorders=4 /logs/access.log
```

## Contribute

Pull requests are very welcome!

We'd love to hear your feedback and suggestions in the issue tracker: [github.com/matomo-org/docker/issues](https://github.com/matomo-org/docker/issues).

## GeoIP

~~This product includes GeoLite data created by MaxMind, available from [https://www.maxmind.com](https://www.maxmind.com).~~ https://blog.maxmind.com/2019/12/18/significant-changes-to-accessing-and-using-geolite2-databases/
