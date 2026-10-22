# syntax=docker/dockerfile:1

# Build one of the variants with --build-arg VARIANT=apache|fpm|fpm-alpine (default: apache),
# or the nginx image that serves the static files for the fpm variants with --target web.
ARG VARIANT=apache
ARG PHP_VERSION=8.4
ARG MATOMO_VERSION=5.14.2

# --- download and verify the Matomo release ---------------------------------------------------------------------------
FROM alpine:3.24 AS source
ARG MATOMO_VERSION

RUN set -eux; \
	apk add --no-cache curl gnupg; \
	\
	cd /tmp; \
	curl -fsSL -o matomo.tar.gz \
		"https://builds.matomo.org/matomo-${MATOMO_VERSION}.tar.gz"; \
	curl -fsSL -o matomo.tar.gz.asc \
		"https://builds.matomo.org/matomo-${MATOMO_VERSION}.tar.gz.asc"; \
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --keyserver keyserver.ubuntu.com --recv-keys F529A27008477483777FC23D63BB30D0E5D2C749; \
	gpg --batch --verify matomo.tar.gz.asc matomo.tar.gz; \
	tar -xzf matomo.tar.gz -C /; \
	rm -rf "$GNUPGHOME" matomo.tar.gz matomo.tar.gz.asc

# --- make the release run from read-only files ------------------------------------------------------------------------
FROM php:${PHP_VERSION}-cli-alpine AS prepare

COPY --from=source /matomo /matomo
COPY bootstrap.php /matomo/

RUN set -eux; \
	cd /matomo; \
# Matomo writes its .htaccess files when it gets installed, which it can't do anymore with read-only code
# (the warning about the missing config.ini.php is expected)
	php console core:create-security-files; \
	rm -rf /var/lib/matomo; \
# the config moved to /var/lib/matomo, but keep this directory of the release closed as well
	cp core/.htaccess config/.htaccess; \
# so does tmp, but a diagnostic of Matomo still writes into this one
	rmdir tmp; \
	ln -s /var/lib/matomo/tmp tmp; \
	\
# the tracker is rebuilt by Matomo when plugins extend it, so it has to live in the data volume
	ln -s /var/lib/matomo/public public; \
	ln -sf public/matomo.js matomo.js; \
	ln -sf public/piwik.js piwik.js

# --- PHP base images, one per variant ---------------------------------------------------------------------------------
# ENTRYPOINT and CMD are set here because setting ENTRYPOINT in a later stage would reset the CMD inherited from here
FROM php:${PHP_VERSION}-apache AS base-apache

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends procps; \
	apt-get dist-clean; \
	a2enmod rewrite; \
# virtual hosts only run the rewrite rules of the server config (see matomo.conf) when they enable the engine themselves
	sed -i 's|^</VirtualHost>|\tRewriteEngine On\n</VirtualHost>|' /etc/apache2/sites-available/000-default.conf; \
	grep -q 'RewriteEngine On' /etc/apache2/sites-available/000-default.conf

COPY apache.conf /etc/apache2/conf-available/matomo.conf
RUN a2enconf matomo

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["apache2-foreground"]

FROM php:${PHP_VERSION}-fpm AS base-fpm

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends procps; \
	apt-get dist-clean

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]

FROM php:${PHP_VERSION}-fpm-alpine AS base-fpm-alpine

RUN apk add --no-cache procps

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]

# --- nginx serving the static files for the fpm variants --------------------------------------------------------------
FROM nginx:1.30-alpine AS web

# the address of php-fpm, and the resolvers to look it up with
ENV MATOMO_FPM_ADDRESS=app:9000 \
	NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1

COPY --link --chown=0:0 --from=prepare /matomo /var/www/html
COPY nginx.conf /etc/nginx/templates/default.conf.template

# --- Matomo -----------------------------------------------------------------------------------------------------------
FROM base-${VARIANT}
ARG MATOMO_VERSION

ENV MATOMO_VERSION=${MATOMO_VERSION} \
	PHP_MEMORY_LIMIT=256M

COPY --link --from=mlocati/php-extension-installer:2.12.3 /usr/bin/install-php-extensions /usr/local/bin/

RUN install-php-extensions \
	apcu-5.1.28 \
	bcmath \
	gd \
	ldap \
	mysqli \
	pdo_mysql \
	redis-6.3.0 \
	zip

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN { \
		echo 'opcache.memory_consumption=128'; \
		echo 'opcache.interned_strings_buffer=8'; \
		echo 'opcache.max_accelerated_files=4000'; \
		echo 'opcache.revalidate_freq=2'; \
		echo 'opcache.fast_shutdown=1'; \
	} > /usr/local/etc/php/conf.d/opcache-recommended.ini

COPY php.ini /usr/local/etc/php/conf.d/php-matomo.ini

# loaded by /var/lib/matomo/config/config.php, which the entrypoint creates
COPY matomo-config.php /usr/local/share/matomo/config.php

COPY --link --chown=0:0 --from=prepare /matomo /var/www/html

COPY docker-entrypoint.sh /usr/local/bin/

RUN set -eux; \
# the PHP images let www-data write into /var/www/html, but now it may only read the code
	chown root:root /var/www/html; \
	chmod 755 /var/www/html; \
# Matomo's plugin installer insists on a writable plugins/ although it installs into MATOMO_PLUGIN_COPY_DIR,
# the sticky bit keeps the plugins of the release from being renamed or removed
	chmod 1777 /var/www/html/plugins; \
	mkdir /var/lib/matomo; \
	chown www-data:www-data /var/lib/matomo

VOLUME /var/lib/matomo

LABEL org.opencontainers.image.title="Matomo" \
	org.opencontainers.image.description="Matomo, the open-source web analytics platform" \
	org.opencontainers.image.url="https://matomo.org" \
	org.opencontainers.image.source="https://github.com/matomo-org/docker" \
	org.opencontainers.image.version="${MATOMO_VERSION}"
