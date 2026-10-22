<?php
// Matomo Docker image: the code is read-only, everything Matomo writes lives in /var/lib/matomo
// (loaded by every Matomo entry point before anything else, as /var/www/html/bootstrap.php)
define('PIWIK_USER_PATH', '/var/lib/matomo');

// plugins installed from the Marketplace (/var/www/html/public is a link to /var/lib/matomo/public)
$GLOBALS['MATOMO_PLUGIN_DIRS'][] = [
    'pluginsPathAbsolute' => '/var/lib/matomo/public/plugins/',
    'webrootDirRelativeToMatomo' => 'public/plugins',
];
$GLOBALS['MATOMO_PLUGIN_COPY_DIR'] = '/var/lib/matomo/public/plugins/';
