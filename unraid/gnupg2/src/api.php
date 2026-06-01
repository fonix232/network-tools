<?php
/*
 * gnupg2 -- API endpoint
 * Installed to: /usr/local/emhttp/plugins/gnupg2/api.php
 *
 * Called via AJAX from the management page.
 * Returns JSON: { "ok": bool, ... }
 */

header('Content-Type: application/json');

$FLASH_GPG  = '/boot/config/gnupg';
$EXTRA_DIR  = '/boot/extra';
$PKG_DB     = '/var/lib/pkgtools/packages';
$PACKAGES   = ['gnupg2', 'libassuan', 'libksba', 'npth'];

function api_json(bool $ok, string $msg): void {
    echo json_encode(['ok' => $ok, 'msg' => $msg]);
    if (ob_get_level()) ob_end_flush();
    flush();
    exit;
}

function installed_version(string $name): string {
    global $PKG_DB;
    $matches = glob("$PKG_DB/$name-*");
    foreach ($matches as $m) {
        $base = basename($m);
        // Slackware package names: name-version-arch-build
        if (preg_match('/^' . preg_quote($name, '/') . '-([^-]+-[^-]+-[^-]+)$/', $base, $hit)) {
            return $hit[1];
        }
    }
    return '';
}

function slackware_mirror(): string {
    // Detect Slackware version — Unraid 7.x reports "Slackware 15.0+" (trailing +) and tracks -current
    $ver = trim(@file_get_contents('/etc/slackware-version') ?: '');
    if (str_contains($ver, '+') || $ver === '') {
        return 'https://mirrors.slackware.com/slackware/slackware64-current';
    }
    if (preg_match('/Slackware\s+([\d.]+)/', $ver, $m)) {
        return "https://mirrors.slackware.com/slackware/slackware64-{$m[1]}";
    }
    return 'https://mirrors.slackware.com/slackware/slackware64-current';
}

function lookup_package(string $name, string $checksums): ?array {
    // Find the package path in CHECKSUMS.md5 without assuming category
    if (!preg_match('#([a-f0-9]+)\s+\./slackware64/([^/]+)/(' . preg_quote($name, '#') . '-[^\s]+\.txz)$#m', $checksums, $m)) {
        return null;
    }
    return ['cat' => $m[2], 'filename' => $m[3], 'md5' => $m[1]];
}

$action = $_POST['action'] ?? $_GET['action'] ?? '';

switch ($action) {

    case 'status':
        $pkgs = [];
        foreach ($PACKAGES as $name) {
            $ver = installed_version($name);
            $extra = glob("$EXTRA_DIR/$name-*.t?z");
            $pkgs[] = [
                'name'      => $name,
                'installed' => $ver,
                'in_extra'  => count($extra) > 0,
                'extra_file' => $extra ? basename($extra[0]) : '',
            ];
        }

        // GPG keys
        $keys = [];
        exec('gpg --batch --with-colons --list-keys 2>/dev/null', $pub_out);
        exec('gpg --batch --with-colons --list-secret-keys 2>/dev/null', $sec_out);
        $sec_fps = [];
        foreach ($sec_out as $line) {
            $fields = explode(':', $line);
            if ($fields[0] === 'fpr') $sec_fps[] = $fields[9];
        }

        $cur = null;
        $last_type = '';
        foreach ($pub_out as $line) {
            $f = explode(':', $line);
            if ($f[0] === 'pub') {
                if ($cur) $keys[] = $cur;
                $last_type = 'pub';
                $cur = [
                    'algo'    => $f[3],
                    'bits'    => $f[2],
                    'keyid'   => $f[4],
                    'created' => $f[5],
                    'expires' => $f[6],
                    'trust'   => $f[1],
                    'caps'    => $f[11] ?? '',
                    'fpr'     => '',
                    'uid'     => '',
                    'secret'  => false,
                    'subs'    => [],
                ];
            }
            if ($f[0] === 'sub' && $cur) {
                $last_type = 'sub';
                $cur['subs'][] = [
                    'algo'  => $f[3],
                    'bits'  => $f[2],
                    'keyid' => $f[4],
                    'caps'  => $f[11] ?? '',
                    'fpr'   => '',
                ];
            }
            if ($f[0] === 'fpr' && $cur) {
                if ($last_type === 'sub' && $cur['subs']) {
                    $idx = count($cur['subs']) - 1;
                    if ($cur['subs'][$idx]['fpr'] === '') $cur['subs'][$idx]['fpr'] = $f[9];
                } elseif ($cur['fpr'] === '') {
                    $cur['fpr'] = $f[9];
                    $cur['secret'] = in_array($f[9], $sec_fps);
                }
            }
            if ($f[0] === 'uid' && $cur && $cur['uid'] === '') {
                $cur['uid'] = $f[9];
            }
        }
        if ($cur) $keys[] = $cur;

        $flash_ok = is_dir($FLASH_GPG);
        echo json_encode(['ok' => true, 'packages' => $pkgs, 'keys' => $keys, 'flash_backup' => $flash_ok]);
        exit;

    case 'check_updates':
        $mirror = slackware_mirror();
        $ctx = stream_context_create(['http' => [
            'timeout'       => 15,
            'user_agent'    => 'gnupg2-unraid/1.0',
            'ignore_errors' => true,
        ]]);
        $checksums = @file_get_contents("$mirror/CHECKSUMS.md5", false, $ctx);
        if (!$checksums) {
            api_json(false, "Could not fetch package list from mirror:\n$mirror/CHECKSUMS.md5");
        }

        $results = [];
        foreach ($PACKAGES as $name) {
            $pkg = lookup_package($name, $checksums);
            if (!$pkg) continue;
            $results[] = [
                'name'      => $name,
                'filename'  => $pkg['filename'],
                'md5'       => $pkg['md5'],
                'url'       => "$mirror/slackware64/{$pkg['cat']}/{$pkg['filename']}",
                'installed' => installed_version($name),
            ];
        }
        if (empty($results)) {
            api_json(false, "No matching packages found in $mirror");
        }
        echo json_encode(['ok' => true, 'packages' => $results, 'mirror' => $mirror]);
        exit;

    case 'install_packages':
        $mirror = slackware_mirror();
        $ctx = stream_context_create(['http' => [
            'timeout'       => 15,
            'user_agent'    => 'gnupg2-unraid/1.0',
            'ignore_errors' => true,
        ]]);
        $checksums = @file_get_contents("$mirror/CHECKSUMS.md5", false, $ctx);
        if (!$checksums) {
            api_json(false, "Could not fetch package list from mirror.");
        }

        @mkdir($EXTRA_DIR, 0755, true);
        $log = [];

        foreach ($PACKAGES as $name) {
            $pkg = lookup_package($name, $checksums);
            if (!$pkg) {
                $log[] = "$name: not found in mirror";
                continue;
            }

            $filename = $pkg['filename'];
            $url = "$mirror/slackware64/{$pkg['cat']}/$filename";
            $dest = "$EXTRA_DIR/$filename";
            $expected_md5 = $pkg['md5'];

            // Remove old versions from /boot/extra
            foreach (glob("$EXTRA_DIR/$name-*.t?z") as $old) {
                if ($old !== $dest) unlink($old);
            }

            // Download
            exec('curl -fsSL ' . escapeshellarg($url) . ' -o ' . escapeshellarg($dest) . ' 2>&1', $out, $rc);
            if ($rc !== 0 || !file_exists($dest)) {
                $log[] = "$name: download failed";
                continue;
            }

            // Verify MD5
            $actual_md5 = md5_file($dest);
            if ($actual_md5 !== $expected_md5) {
                unlink($dest);
                $log[] = "$name: MD5 mismatch (expected $expected_md5, got $actual_md5)";
                continue;
            }

            // Install/upgrade
            exec('upgradepkg --install-new ' . escapeshellarg($dest) . ' 2>&1', $inst_out, $inst_rc);
            $log[] = "$name: installed $filename" . ($inst_rc !== 0 ? " (exit $inst_rc)" : "");
        }

        api_json(true, implode("\n", $log));
        break;

    case 'generate_key':
        $name  = trim($_POST['key_name'] ?? '');
        $email = trim($_POST['key_email'] ?? '');
        if ($name === '') api_json(false, 'Name is required.');

        // Validate algorithm
        $valid_algos = ['ed25519', 'rsa2048', 'rsa4096', 'nistp256', 'nistp384', 'nistp521'];
        $algo = in_array($_POST['key_algo'] ?? '', $valid_algos) ? $_POST['key_algo'] : 'ed25519';

        // Validate usages — cert is always required on a primary key
        $valid_usage_items = ['sign', 'cert', 'auth'];
        $raw_usages = array_filter(
            array_map('trim', explode(',', $_POST['key_usages'] ?? 'sign,cert')),
            fn($u) => in_array($u, $valid_usage_items)
        );
        if (!in_array('cert', $raw_usages)) $raw_usages[] = 'cert';
        $usages = implode(',', array_unique($raw_usages));

        $add_encr = ($_POST['key_encr'] ?? '1') === '1';

        $uid = $email !== '' ? "$name <$email>" : $name;
        exec('gpg --batch --passphrase "" --quick-gen-key '
            . escapeshellarg($uid) . ' '
            . escapeshellarg($algo) . ' '
            . escapeshellarg($usages) . ' never 2>&1', $out, $rc);
        if ($rc !== 0) {
            api_json(false, "Key generation failed:\n" . implode("\n", $out));
        }

        // Get the fingerprint of the newly created key
        exec('gpg --batch --with-colons --list-key ' . escapeshellarg($uid) . ' 2>/dev/null', $list_out);
        $fpr = '';
        foreach ($list_out as $line) {
            $f = explode(':', $line);
            if ($f[0] === 'fpr' && $fpr === '') { $fpr = $f[9]; break; }
        }

        // Add encryption subkey (algo paired with primary)
        if ($add_encr && $fpr !== '') {
            $encr_algo_map = [
                'ed25519' => 'cv25519', 'rsa2048' => 'rsa2048', 'rsa4096' => 'rsa4096',
                'nistp256' => 'nistp256', 'nistp384' => 'nistp384', 'nistp521' => 'nistp521',
            ];
            $encr_algo = $encr_algo_map[$algo] ?? 'cv25519';
            exec('gpg --batch --passphrase "" --quick-add-key '
                . escapeshellarg($fpr) . ' '
                . escapeshellarg($encr_algo) . ' encr never 2>&1', $sub_out, $sub_rc);
            if ($sub_rc !== 0) {
                api_json(false, "Key created but encryption subkey failed:\n" . implode("\n", $sub_out));
            }
            $out = array_merge($out, $sub_out);
        }

        // Backup to flash
        exec('rsync -a --delete --exclude="S.*" --exclude="*.lock" --exclude=".#lk*" /root/.gnupg/ ' . escapeshellarg($FLASH_GPG) . '/ 2>&1');
        api_json(true, "Key generated for: $uid\n" . implode("\n", $out));
        break;

    case 'delete_key':
        $fpr = preg_replace('/[^A-Fa-f0-9]/', '', $_POST['fingerprint'] ?? '');
        if (strlen($fpr) < 16) api_json(false, 'Invalid fingerprint.');

        exec('gpg --batch --yes --delete-secret-and-public-key ' . escapeshellarg($fpr) . ' 2>&1', $out, $rc);
        if ($rc !== 0) {
            // May not have secret key, try public only
            exec('gpg --batch --yes --delete-keys ' . escapeshellarg($fpr) . ' 2>&1', $out2, $rc2);
            if ($rc2 !== 0) {
                api_json(false, "Delete failed:\n" . implode("\n", array_merge($out, $out2)));
            }
        }
        exec('rsync -a --delete --exclude="S.*" --exclude="*.lock" --exclude=".#lk*" /root/.gnupg/ ' . escapeshellarg($FLASH_GPG) . '/ 2>&1');
        api_json(true, "Deleted key $fpr");
        break;

    case 'export_key':
        $fpr = preg_replace('/[^A-Fa-f0-9]/', '', $_GET['fingerprint'] ?? '');
        if (strlen($fpr) < 16) api_json(false, 'Invalid fingerprint.');
        exec('gpg --batch --armor --export ' . escapeshellarg($fpr) . ' 2>&1', $out, $rc);
        if ($rc !== 0 || empty($out)) {
            api_json(false, "Export failed:\n" . implode("\n", $out));
        }
        echo json_encode(['ok' => true, 'armor' => implode("\n", $out)]);
        exit;

    case 'import_key':
        $armor = $_POST['armor'] ?? '';
        if (strlen($armor) < 50 || strlen($armor) > 65536) {
            api_json(false, 'Key data rejected: too short or too large.');
        }
        $tmp = tempnam('/tmp', 'gpg-import-');
        file_put_contents($tmp, $armor);
        exec('gpg --batch --import ' . escapeshellarg($tmp) . ' 2>&1', $out, $rc);
        @unlink($tmp);
        if ($rc !== 0) {
            api_json(false, "Import failed:\n" . implode("\n", $out));
        }
        exec('rsync -a --delete --exclude="S.*" --exclude="*.lock" --exclude=".#lk*" /root/.gnupg/ ' . escapeshellarg($FLASH_GPG) . '/ 2>&1');
        api_json(true, "Key imported.\n" . implode("\n", $out));
        break;

    case 'backup':
        @mkdir($FLASH_GPG, 0700, true);
        exec('rsync -a --delete --exclude="S.*" --exclude="*.lock" --exclude=".#lk*" /root/.gnupg/ ' . escapeshellarg($FLASH_GPG) . '/ 2>&1', $out, $rc);
        api_json($rc === 0, $rc === 0 ? 'Keyring backed up to flash.' : "Backup failed:\n" . implode("\n", $out));
        break;

    case 'restore':
        if (!is_dir($FLASH_GPG)) {
            api_json(false, 'No backup found on flash.');
        }
        exec('rsync -a --exclude="S.*" --exclude="*.lock" --exclude=".#lk*" ' . escapeshellarg($FLASH_GPG) . '/ /root/.gnupg/ 2>&1', $out, $rc);
        api_json($rc === 0, $rc === 0 ? 'Keyring restored from flash.' : "Restore failed:\n" . implode("\n", $out));
        break;

    default:
        api_json(false, "Unknown action: $action");
}
