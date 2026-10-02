<?php
/*
 * Komodo Periphery -- API endpoint
 * Installed to: /usr/local/emhttp/plugins/komodo-periphery/api.php
 *
 * Called via AJAX from the management page.
 * Returns JSON: { "ok": bool, "msg": string } unless noted otherwise.
 *
 * The $PINNED_TAG placeholder below is replaced at assembly time with the
 * KOMODO_VERSION pin from the repo-root versions.env, so every build of this
 * plugin knows which Periphery release it targets without asking GitHub.
 */

header('Content-Type: application/json');

$PLUGIN_DIR = '/boot/config/plugins/komodo-periphery';
$RC         = "$PLUGIN_DIR/rc.komodo-periphery";
$BINARY     = "$PLUGIN_DIR/periphery";
$FLASH_CFG  = '/boot/config/komodo-periphery/periphery.config.toml';
$LIVE_CFG   = '/etc/komodo/periphery.config.toml';
$VER_FILE   = "$PLUGIN_DIR/version";
$PIDFILE    = '/var/run/komodo-periphery.pid';
$ARCH       = 'x86_64';

// The pinned release this plugin build targets. An unsubstituted placeholder
// (source copied by hand rather than assembled) degrades to "no pin".
$PINNED_TAG = '__KOMODO_VERSION__';
if (strncmp($PINNED_TAG, '__', 2) === 0) $PINNED_TAG = '';
// Release tags carry a v prefix; accept a pin written without one.
if ($PINNED_TAG !== '' && ctype_digit($PINNED_TAG[0])) $PINNED_TAG = 'v' . $PINNED_TAG;

function api_json(bool $ok, string $msg): void {
    echo json_encode(['ok' => $ok, 'msg' => $msg]);
    if (ob_get_level()) ob_end_flush();
    flush();
    exit;
}

/* /boot is FAT32, so the execute bit on the rc script cannot be relied on --
 * always invoke it through sh. */
function kp_rc(string $verb): array {
    global $RC;
    @chmod($RC, 0755);
    exec('sh ' . escapeshellarg($RC) . ' ' . escapeshellarg($verb) . ' 2>&1', $out, $rc);
    return [$rc, implode("\n", $out)];
}

function kp_running(): bool {
    global $PIDFILE;
    if (!file_exists($PIDFILE)) return false;
    $pid = (int) trim((string) @file_get_contents($PIDFILE));
    return $pid > 0 && file_exists("/proc/$pid");
}

function kp_installed_tag(): string {
    global $VER_FILE;
    return file_exists($VER_FILE) ? trim((string) file_get_contents($VER_FILE)) : '';
}

/* Compare release tags ignoring the v prefix. -1 / 0 / 1 like version_compare. */
function kp_cmp(string $a, string $b): int {
    return version_compare(ltrim($a, 'vV'), ltrim($b, 'vV'));
}

function kp_clean_tag(string $tag): string {
    return preg_replace('/[^a-zA-Z0-9.\-]/', '', $tag);
}

/* Stable release tags from GitHub, newest first. Empty array on any failure. */
function kp_release_tags(int $count = 10): array {
    $ctx = stream_context_create(['http' => [
        'timeout'       => 10,
        'user_agent'    => 'komodo-periphery-unraid/1.0',
        'ignore_errors' => true,
    ]]);
    $json = @file_get_contents(
        'https://api.github.com/repos/moghtech/komodo/releases?per_page=' . $count,
        false, $ctx
    );
    $data = json_decode($json ?: '[]', true);
    $tags = [];
    if (is_array($data)) {
        foreach ($data as $r) {
            if (!($r['prerelease'] ?? true) && isset($r['tag_name'])) $tags[] = $r['tag_name'];
        }
    }
    return $tags;
}

/* Download $tag and swap it in. Stops the daemon first when it is running --
 * rc stop flushes /etc/komodo (config, keys, certs) to flash and rc start
 * restores it, so the swap preserves configuration. */
function kp_install_tag(string $tag): void {
    global $PLUGIN_DIR, $BINARY, $VER_FILE, $ARCH;

    $url = "https://github.com/moghtech/komodo/releases/download/$tag/periphery-$ARCH";
    $tmp = "$PLUGIN_DIR/periphery.tmp";
    @mkdir($PLUGIN_DIR, 0755, true);

    exec('curl -fsSL ' . escapeshellarg($url) . ' -o ' . escapeshellarg($tmp) . ' 2>&1', $out, $rc);

    if ($rc !== 0 || !file_exists($tmp) || filesize($tmp) < 1024) {
        @unlink($tmp);
        api_json(false, "Download failed for $tag:\n" . implode("\n", $out));
    }

    $log = [];
    $was_running = kp_running();
    if ($was_running) {
        [, $stop_out] = kp_rc('stop');
        $log[] = $stop_out;
    }

    if (!rename($tmp, $BINARY)) {
        @unlink($tmp);
        api_json(false, "Could not replace $BINARY.");
    }
    chmod($BINARY, 0755);
    file_put_contents($VER_FILE, $tag);

    [, $start_out] = kp_rc('start');
    $log[] = $start_out;

    api_json(true, "Periphery $tag installed.\n" . trim(implode("\n", $log)));
}

$action = $_POST['action'] ?? $_GET['action'] ?? '';

switch ($action) {

    case 'start':
    case 'stop':
    case 'restart':
        [$rc, $out] = kp_rc($action);
        api_json($rc === 0, $out);
        break;

    /* install: explicit tag from the UI, or the pinned release when omitted.
     * update:  same, but a no-op when the target is already installed. */
    case 'install':
    case 'update':
        $tag = kp_clean_tag($_POST['tag'] ?? '');
        if ($tag === '') $tag = $PINNED_TAG;
        if ($tag === '')
            api_json(false, 'No version tag supplied, and this plugin build carries no pinned version.');

        $installed = kp_installed_tag();
        $force     = ($_POST['force'] ?? '') === '1';

        if ($action === 'update' && !$force && $installed !== '' && kp_cmp($installed, $tag) === 0)
            api_json(true, "Already on $installed -- nothing to do.");

        kp_install_tag($tag);
        break;

    /* Update check. The pinned comparison is offline: this plugin build knows
     * its target release, so a plugin update is what delivers a new target.
     * The upstream comparison needs GitHub and is best-effort. */
    case 'check_update':
        $installed = kp_installed_tag();
        $tags      = kp_release_tags(10);
        $latest    = $tags[0] ?? '';

        echo json_encode([
            'ok'        => true,
            'installed' => $installed,
            'pinned'    => $PINNED_TAG,
            'latest'    => $latest,
            'tags'      => $tags,
            'pinned_update_available' =>
                $PINNED_TAG !== '' && $installed !== '' && kp_cmp($installed, $PINNED_TAG) < 0,
            'upstream_update_available' =>
                $latest !== '' && kp_cmp($PINNED_TAG !== '' ? $PINNED_TAG : $installed, $latest) < 0,
            'msg' => $latest === '' ? 'Could not reach GitHub; pinned comparison only.' : '',
        ]);
        exit;

    case 'save_restart':
    case 'save':
        $cfg = $_POST['config'] ?? '';
        if (strlen($cfg) === 0 || strlen($cfg) > 262144)
            api_json(false, 'Config rejected: empty or too large.');
        @mkdir(dirname($LIVE_CFG), 0755, true);
        @mkdir(dirname($FLASH_CFG), 0755, true);
        file_put_contents($LIVE_CFG, $cfg);
        file_put_contents($FLASH_CFG, $cfg);
        if ($action === 'save_restart') {
            [, $out2] = kp_rc('restart');
            api_json(true, 'Config saved. Restarting…' . "\n" . $out2);
        }
        api_json(true, 'Config saved. Restart the service to apply.');
        break;

    case 'releases':
        $tags = kp_release_tags(10);
        if (empty($tags)) {
            api_json(false, 'Could not fetch releases from GitHub.');
        }
        echo json_encode(['ok' => true, 'tags' => $tags, 'pinned' => $PINNED_TAG]);
        exit;

    default:
        api_json(false, "Unknown action: $action");
}
