<?php

  require_once("pkg-utils.inc");
  require_once("notices.inc");
  require_once("util.inc");

  $msg = null;
  $pmsg = null;
  $p = 0;

  log_error("Starting update check");

  // pfSense base system check
  $system_version = get_system_pkg_version(false, false);
  if ($system_version === false) {
    printf("%s\n", 'Unable to check for updates');
    log_error("Unable to check for updates, exiting");
    exit;
  }

  if (!is_array($system_version) ||
    !isset($system_version['version']) ||
    !isset($system_version['installed_version'])) {
    printf("%s\n", 'Error in version information');
    log_error("Error in version information, exiting");
    exit;
  }

  switch ($system_version['pkg_version_compare']) {
    case '<':
      //printf("%s%s%s\n", "pfSense version ", $system_version['version'], " is available");
      $msg = "An update to pfSense version " . $system_version['version'] . " is available\n\n";
      break;
    case '=':
      //printf("%s%s%s\n", "pfSense version ", $system_version['version'], " (installed) is current");
      break;
    case '>':
      printf("%s%s%s\n", "pfSense version ", $system_version['installed_version'], " is NEWER than the latest available version ", $system_version['version']);
      $msg = "pfSense version " . $system_version['version'] . " is available (downgrade)\n\n";
      break;
    default:
      printf("%s\n", 'Error comparing installed with latest version available');
      log_error("Error comparing installed with latest version available");
      break;
  }

  // package check
  $package_list = get_pkg_info('all', true, true);
  $installed_packages = array_filter($package_list, function($v) {
    return (isset($v['installed']) && isset($v['name']));
  });

  if (empty($installed_packages)) {
    printf("%s\n", 'No packages installed');
    log_error("No packages installed");
  } else {
	  foreach ($installed_packages as $pkg) {
		if (isset($pkg['installed_version']) && isset($pkg['version'])) {
		  //printf("%s%s%s\n", $pkg['shortname'], ': ', $pkg['installed_version']);
		  $version_compare = pkg_version_compare($pkg['installed_version'], $pkg['version']);
		  if ($version_compare != '=') {
			$p++;
			$pmsg .= "\n".$pkg['shortname'].': '.$pkg['installed_version'].' ==> '.$pkg['version'];
			if ($version_compare == '>') {
			  $pmsg .= ' (downgrade)';
			}
			printf("%s%s%s%s%s\n", $pkg['shortname'], ': ', $pkg['installed_version'], ' ==> ', $pkg['version']);
		  }
		}
	  }
  }


  if ($p > 0) {
    $msg = $msg . "The following updates are available and can be installed using System > Package Manager:\n" . $pmsg;
  }

  // check for updates to builtin packages
  exec("/usr/sbin/pkg upgrade -n | /usr/bin/sed -ne '/UPGRADED/,/^$/p'", $output, $retval);
  if (($retval == 0) && (count($output))) {
    $msg .= "\n\n" . "Some packages are part of the base system and will not show up in Package Manager. If any such updates are listed below, run `pkg upgrade` from the shell to install them:\n\n";
    array_shift($output);
    $msg .= implode("\n", array_map('ltrim', $output));
  }

  if (!empty($msg)) {
    log_error("Updates were found - sending email");
    // notify_via_smtp($msg);
    // to send alerts to ALL configured targets (email, Pushover, Slack etc) use the line below instead:
    notify_all_remote($msg);
  }

  log_error("Update check complete");

?>
