#!/bin/sh
set -e

# the code of the image, read-only
code=/var/www/html
# everything Matomo writes (PIWIK_USER_PATH, set in $code/bootstrap.php)
data=/var/lib/matomo

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	local varValue=$(env | grep -E "^${var}=" | sed -E -e "s/^${var}=//")
	local fileVarValue=$(env | grep -E "^${fileVar}=" | sed -E -e "s/^${fileVar}=//")
	if [ -n "${varValue}" ] && [ -n "${fileVarValue}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	if [ -n "${varValue}" ]; then
		export "$var"="${varValue}"
	elif [ -n "${fileVarValue}" ]; then
		export "$var"="$(cat "${fileVarValue}")"
	elif [ -n "${def}" ]; then
		export "$var"="$def"
	fi
	unset "$fileVar"
}

# usage: matomo_version DIR
# (prints the version of the Matomo installed in DIR, or nothing if it can't be determined)
matomo_version() {
	sed -n "s/^[[:space:]]*public const VERSION = '\([0-9][0-9.]*\)';.*/\1/p" "$1/core/Version.php" 2> /dev/null || true
}

# usage: lock_upgrade
# (takes the lock on file descriptor 9, waiting for as long as another process is upgrading Matomo)
lock_upgrade() {
	if ! flock -n 9; then
		echo >&2 "Another process is upgrading Matomo. Waiting..."
		flock 9
	fi
}

# usage: run_as CMD
# (runs CMD as the owner of the Matomo files, so that the files it creates stay usable by the web server)
run_as() {
	if [ "$uid" = '0' ]; then
		su -p "$user" -s /bin/sh -c "$1"
	else
		sh -c "$1"
	fi
}

# usage: prepare_data
# (creates what Matomo expects to find in the data directory, which is the current directory)
prepare_data() {
	mkdir -p config tmp misc public/plugins public/js public/misc/user
	touch .upgrade.lock

	# Matomo looks for its environment configs next to config.ini.php
	if [ ! -e config/environment ] && [ ! -L config/environment ]; then
		ln -s "$code/config/environment" config/environment
	fi

	if [ ! -e config/config.php ]; then
		cat > config/config.php <<-'EOF'
			<?php
			// Created by the Matomo image, which needs the definitions in /usr/local/share/matomo/config.php.
			// To add your own, merge them: return array_merge(require '/usr/local/share/matomo/config.php', [...]);
			return require '/usr/local/share/matomo/config.php';
		EOF
	elif ! grep -q '/usr/local/share/matomo/config.php' config/config.php; then
		echo >&2 "warning: $data/config/config.php doesn't load /usr/local/share/matomo/config.php, so GeoIP, the Tag Manager and custom logos will try to write into the read-only code"
	fi

	# Matomo adds the tracking code of plugins to these files
	for file in matomo.js piwik.js; do
		if [ ! -e "public/$file" ]; then
			cp "$code/js/piwik.min.js" "public/$file"
		fi
	done

	# keep the directories that the web server can reach as closed as their counterparts in the code (for Apache)
	cp "$code/core/.htaccess" tmp/.htaccess
	cp "$code/plugins/.htaccess" public/plugins/.htaccess
	cp "$code/js/.htaccess" public/js/.htaccess
	cp "$code/misc/.htaccess" public/misc/.htaccess
}

# usage: upgrade_matomo
# (upgrades the database to the version of the code and rebuilds the JavaScript tracker from the new code)
upgrade_matomo() {
	echo >&2 "Upgrading the database and the JavaScript tracker of Matomo to $MATOMO_VERSION ..."

	if ! run_as "php $code/console core:update --yes --no-interaction"; then
		echo >&2 "error: the database upgrade failed (retry with: php console core:update)"
		return
	fi

	if ! run_as "php $code/console custom-matomo-js:update --no-interaction"; then
		echo >&2 "error: the JavaScript tracker could not be updated (retry with: php console custom-matomo-js:update)"
		return
	fi

	echo "$MATOMO_VERSION" > .matomo-version
	if [ "$uid" = '0' ]; then
		chown "$user":"$group" .matomo-version
	fi
	echo >&2 "Matomo is up to date ($MATOMO_VERSION)"
}

file_env 'MATOMO_DATABASE_HOST'
file_env 'MATOMO_DATABASE_USERNAME'
file_env 'MATOMO_DATABASE_PASSWORD'
file_env 'MATOMO_DATABASE_DBNAME'

# older images kept Matomo in a volume on $code, which would now hide the code of this image
code_version="$(matomo_version "$code")"
if [ "$code_version" != "$MATOMO_VERSION" ]; then
	echo >&2 "error: $code contains Matomo ${code_version:-of an unknown version} instead of $MATOMO_VERSION, the version of this image."
	echo >&2 "       Is the volume of an older image mounted on $code? Matomo's data now belongs into a volume on $data,"
	echo >&2 "       see \"Migrating from older images\" in the README."
	exit 1
fi

uid="$(id -u)"
gid="$(id -g)"
if [ "$uid" = '0' ]; then
	case "$1" in
		apache2*)
			user="${APACHE_RUN_USER:-www-data}"
			group="${APACHE_RUN_GROUP:-www-data}"

			# strip off any '#' symbol ('#1000' is valid syntax for Apache)
			user="${user#'#'}"
			group="${group#'#'}"
			;;
		*) # php-fpm
			user='www-data'
			group='www-data'
			;;
	esac
else
	user="$uid"
	group="$gid"
fi

workdir="$PWD"
cd "$data"

if [ ! -w . ]; then
	echo >&2 "error: $data is not writable by user $(id -u), mount a volume there that is"
	exit 1
fi
prepare_data
if [ "$uid" = '0' ]; then
	# also catches new volumes, bind mounts and files that "php console" created as root
	find . \( ! -user "$user" -o ! -group "$group" \) -exec chown -h "$user":"$group" {} +
fi

if [ -e config/config.ini.php ] && [ "$(cat .matomo-version 2> /dev/null)" != "$MATOMO_VERSION" ]; then
	if [ "${MATOMO_AUTO_UPGRADE:-1}" = '0' ]; then
		echo >&2 "warning: not upgrading Matomo to $MATOMO_VERSION (MATOMO_AUTO_UPGRADE=0), run: php console core:update && php console custom-matomo-js:update"
	else
		# only one container at a time may upgrade a shared volume
		(
			lock_upgrade

			# it might have done the job in the meantime
			if [ "$(cat .matomo-version 2> /dev/null)" != "$MATOMO_VERSION" ]; then
				upgrade_matomo
			fi
		) 9> .upgrade.lock
	fi
fi

cd "$workdir"
exec "$@"
