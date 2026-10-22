<?php
// What the Matomo image needs so that Matomo writes into /var/lib/matomo instead of its read-only code
// (installed as /usr/local/share/matomo/config.php, loaded by /var/lib/matomo/config/config.php)
return [
    // GeoIP databases
    'path.geoip2' => PIWIK_USER_PATH . '/misc/',
    // custom logos and favicons (/var/www/html/public is a link to /var/lib/matomo/public)
    'path.misc.user' => 'public/misc/user/',
    // Tag Manager containers, still available as /js/container_*.js through the web server configuration
    'TagManagerContainerStorageDir' => '/public/js',
    'TagManagerContainerWebDir' => '/js',
];
