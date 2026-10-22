#!/bin/sh
# Tests a fresh, running Compose example (see .github/workflows/ci.yml): installs Matomo through its web installer and
# checks what the image changes about Matomo (read-only code, data in /var/lib/matomo, web server rules).
#
# usage: COMPOSE_FILE=.examples/apache/compose.yml MARIADB_PASSWORD=... tests/smoke-test.sh [URL]
set -eu

url="${1:-http://localhost:8080}"
cookies="$(mktemp)"
trap 'rm -f "$cookies"' EXIT

# usage: app CMD...
# (runs CMD in the Matomo container as the owner of the files)
app() {
	docker compose exec -T --user www-data app "$@"
}

# usage: fail MESSAGE
fail() {
	echo >&2 "error: $1"
	exit 1
}

# usage: expect STATUS PATH
expect() {
	status="$(curl -s -o /dev/null -w '%{http_code}' "$url$2")"
	if [ "$status" != "$1" ]; then
		fail "$2 returned $status instead of $1"
	fi
}

# usage: request URL [CURL ARGS...]
# (a request within the session of the installer)
request() {
	curl -fsS -c "$cookies" -b "$cookies" "$@"
}

# give the entrypoint time to prepare the data volume
for _ in $(seq 60); do
	if curl -fsS -o /dev/null "$url/matomo.js"; then
		break
	fi
	sleep 1
done

# the web server serves the code, but not what has to stay private
expect 200 /
expect 200 /matomo.js
expect 200 /plugins/CoreHome/images/favicon.png
for path in /bootstrap.php /config/global.ini.php /core/Version.php /lang/en.json /plugins/CoreHome/CoreHome.php /tmp/ /vendor/autoload.php; do
	expect 403 "$path"
done

# Matomo can write wherever it needs to (config, tmp, Tag Manager containers, ...)
request -o /dev/null "$url/"
page="$(request "$url/index.php?action=systemCheck")"
case "$page" in
	*'status&quot;:&quot;error'*) fail "the system check of the installer reports errors" ;;
esac

request -o /dev/null "$url/index.php?action=databaseSetup" \
	--data-urlencode host=db \
	--data-urlencode username=matomo \
	--data-urlencode password="$MARIADB_PASSWORD" \
	--data-urlencode dbname=matomo \
	--data-urlencode tables_prefix=matomo_ \
	--data-urlencode 'adapter=PDO\MYSQL' \
	--data-urlencode schema=Mysql
request -o /dev/null "$url/index.php?action=tablesCreation&module=Installation"
request -o /dev/null "$url/index.php?action=setupSuperUser" \
	--data-urlencode login=admin \
	--data-urlencode 'password=smoke-test-Passw0rd' \
	--data-urlencode 'password_bis=smoke-test-Passw0rd' \
	--data-urlencode email=admin@example.org
request -o /dev/null "$url/index.php?action=firstWebsiteSetup" \
	--data-urlencode siteName=Example \
	--data-urlencode url=https://example.org \
	--data-urlencode timezone=UTC \
	--data-urlencode ecommerce=0
request -o /dev/null "$url/index.php?action=trackingCode&module=Installation&site_idSite=1&site_name=Example"
request -o /dev/null "$url/index.php?action=finished&module=Installation" \
	--data-urlencode setup_geoip2=0 \
	--data-urlencode anonymise_ip=1

app test -f /var/lib/matomo/config/config.ini.php || fail "the installer didn't write config/config.ini.php"
page="$(curl -fsS "$url/")"
case "$page" in
	*form_login*) ;;
	*) fail "Matomo doesn't show its login after the installation" ;;
esac

# the code stays read-only for the web server
if app touch /var/www/html/index.php 2> /dev/null; then
	fail "the web server user can write into the code"
fi

# the Tag Manager stores its containers in the data volume, the web server still serves them under /js
app php /var/www/html/console plugin:activate TagManager
container="$(app find /var/lib/matomo/public/js -name 'container_*.js' | head -n 1)"
[ -n "$container" ] || fail "the Tag Manager didn't create a container"
expect 200 "/js/$(basename "$container")"

# the entrypoint brings an installed Matomo up to date when the container starts
version="$(app printenv MATOMO_VERSION)"
app rm -f /var/lib/matomo/.matomo-version
docker compose restart app
for _ in $(seq 60); do
	if [ "$(app cat /var/lib/matomo/.matomo-version 2> /dev/null)" = "$version" ]; then
		echo "Smoke test passed"
		exit 0
	fi
	sleep 1
done
fail "the entrypoint didn't bring Matomo up to date after the restart"
