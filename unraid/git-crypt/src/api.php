<?php
/*
 * git-crypt -- API endpoint
 * Installed to: /usr/local/emhttp/plugins/git-crypt/api.php
 *
 * Called via AJAX from the management page.
 * Returns JSON: { "ok": bool, "msg": string }
 */

header('Content-Type: application/json');

$PLUGIN_DIR   = '/boot/config/plugins/git-crypt';
$CACHED       = "$PLUGIN_DIR/git-crypt";
$INSTALL_PATH = '/usr/local/bin/git-crypt';
$VER_FILE     = "$PLUGIN_DIR/version";
$GITHUB_REPO  = 'AGWA/git-crypt';

function api_json(bool $ok, string $msg): void {
    echo json_encode(['ok' => $ok, 'msg' => $msg]);
    if (ob_get_level()) ob_end_flush();
    flush();
    exit;
}

$action = $_POST['action'] ?? $_GET['action'] ?? '';

switch ($action) {

    case 'install':
        $tag = preg_replace('/[^a-zA-Z0-9.\-]/', '', $_POST['tag'] ?? '');
        if ($tag === '') api_json(false, 'No version tag supplied.');

        // Resolve __latest__ sentinel to the actual latest tag
        if ($tag === '__latest__') {
            $ctx = stream_context_create(['http' => ['timeout' => 10, 'user_agent' => 'git-crypt-unraid/1.0', 'ignore_errors' => true]]);
            $latest_json = @file_get_contents("https://api.github.com/repos/$GITHUB_REPO/releases/latest", false, $ctx);
            $latest_data = json_decode($latest_json ?: '{}', true);
            $tag = preg_replace('/[^a-zA-Z0-9.\-]/', '', $latest_data['tag_name'] ?? '');
            if ($tag === '') api_json(false, 'Could not resolve latest release tag from GitHub.');
        }

        $url = "https://github.com/$GITHUB_REPO/releases/download/$tag/git-crypt-$tag-linux-x86_64";
        $tmp = "$CACHED.tmp";
        @mkdir($PLUGIN_DIR, 0755, true);

        exec('curl -fsSL ' . escapeshellarg($url) . ' -o ' . escapeshellarg($tmp) . ' 2>&1', $out, $rc);

        if ($rc !== 0 || !file_exists($tmp) || filesize($tmp) < 1024) {
            @unlink($tmp);
            api_json(false, "Download failed for $tag:\n" . implode("\n", $out));
        }

        rename($tmp, $CACHED);
        chmod($CACHED, 0755);
        file_put_contents($VER_FILE, $tag);

        // Copy into RAM
        copy($CACHED, $INSTALL_PATH);
        chmod($INSTALL_PATH, 0755);

        exec(escapeshellarg($INSTALL_PATH) . ' --version 2>&1', $ver_out);
        api_json(true, "Installed git-crypt $tag.\n" . implode("\n", $ver_out));

    case 'releases':
        $ctx = stream_context_create(['http' => [
            'timeout'       => 10,
            'user_agent'    => 'git-crypt-unraid/1.0',
            'ignore_errors' => true,
        ]]);
        $json = @file_get_contents(
            "https://api.github.com/repos/$GITHUB_REPO/releases?per_page=10",
            false, $ctx
        );
        $data = json_decode($json ?: '[]', true);
        $tags = [];
        if (is_array($data)) {
            foreach ($data as $r) {
                if (!($r['prerelease'] ?? true) && isset($r['tag_name'])) $tags[] = $r['tag_name'];
            }
        }
        if (empty($tags)) api_json(false, 'Could not fetch releases from GitHub.');
        echo json_encode(['ok' => true, 'tags' => $tags]);
        exit;

    default:
        api_json(false, "Unknown action: $action");
}
