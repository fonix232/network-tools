<?php
/*
 * Komodo Periphery -- API endpoint
 * Installed to: /usr/local/emhttp/plugins/komodo-periphery/api.php
 *
 * Called via AJAX from the management page.
 * Returns JSON: { "ok": bool, "msg": string }
 */

header('Content-Type: application/json');

$PLUGIN_DIR = '/boot/config/plugins/komodo-periphery';
$RC         = "$PLUGIN_DIR/rc.komodo-periphery";
$BINARY     = "$PLUGIN_DIR/periphery";
$FLASH_CFG  = '/boot/config/komodo-periphery/periphery.config.toml';
$LIVE_CFG   = '/etc/komodo/periphery.config.toml';
$VER_FILE   = "$PLUGIN_DIR/version";
$ARCH       = 'x86_64';

function api_json(bool $ok, string $msg): void {
    echo json_encode(['ok' => $ok, 'msg' => $msg]);
    if (ob_get_level()) ob_end_flush();
    flush();
    exit;
}

$action = $_POST['action'] ?? $_GET['action'] ?? '';

switch ($action) {

    case 'start':
    case 'stop':
    case 'restart':
        @chmod($RC, 0755);
        exec('sh ' . escapeshellarg($RC) . ' ' . escapeshellarg($action) . ' 2>&1', $out, $rc);
        api_json($rc === 0, implode("\n", $out));
        break;

    case 'install':
        $tag = preg_replace('/[^a-zA-Z0-9.\-]/', '', $_POST['tag'] ?? '');
        if ($tag === '') api_json(false, 'No version tag supplied.');

        $url = "https://github.com/moghtech/komodo/releases/download/$tag/periphery-$ARCH";
        $tmp = "$PLUGIN_DIR/periphery.tmp";
        @mkdir($PLUGIN_DIR, 0755, true);

        exec('curl -fsSL ' . escapeshellarg($url) . ' -o ' . escapeshellarg($tmp) . ' 2>&1', $out, $rc);

        if ($rc !== 0 || !file_exists($tmp) || filesize($tmp) < 1024) {
            @unlink($tmp);
            api_json(false, "Download failed for $tag:\n" . implode("\n", $out));
        }

        rename($tmp, $BINARY);
        chmod($BINARY, 0755);
        file_put_contents($VER_FILE, $tag);
        exec(escapeshellarg($RC) . ' start 2>&1', $out2);
        api_json(true, "Installed periphery $tag.\n" . implode("\n", $out2));
        break;

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
            @chmod($RC, 0755);
            exec('sh ' . escapeshellarg($RC) . ' restart 2>&1', $out2);
            api_json(true, 'Config saved. Restarting…' . "\n" . implode("\n", $out2));
        }
        api_json(true, 'Config saved. Restart the service to apply.');
        break;

    case 'releases':
        $ctx = stream_context_create(['http' => [
            'timeout'       => 10,
            'user_agent'    => 'komodo-periphery-unraid/1.0',
            'ignore_errors' => true,
        ]]);
        $json = @file_get_contents(
            'https://api.github.com/repos/moghtech/komodo/releases?per_page=10',
            false, $ctx
        );
        $data = json_decode($json ?: '[]', true);
        $tags = [];
        if (is_array($data)) {
            foreach ($data as $r) {
                if (!($r['prerelease'] ?? true) && isset($r['tag_name'])) $tags[] = $r['tag_name'];
            }
        }
        if (empty($tags)) {
            api_json(false, 'Could not fetch releases from GitHub.');
        }
        echo json_encode(['ok' => true, 'tags' => $tags]);
        exit;

    default:
        api_json(false, "Unknown action: $action");
}
