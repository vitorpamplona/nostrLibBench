<?php

/*
 * nostrLibBench PHP harness. Contract: ../HARNESS.md. Run through ./run.sh.
 *
 * Without --child this script is the orchestrator: for every client and workload it starts
 * itself again in a fresh `php` process (`--child <client> --workload <w>`), reads one JSON
 * line per run from it (with a deadline, so a hung library is killed and still gets a row)
 * and writes results/php.json. The child opens the subscription through the library, counts
 * what it delivers and reports each run.
 */

declare(strict_types=1);

require __DIR__ . '/vendor/autoload.php';

use swentel\nostr\Event\Event;
use swentel\nostr\Filter\Filter;
use swentel\nostr\Message\RequestMessage;
use swentel\nostr\Relay\Relay;
use swentel\nostr\RelayResponse\RelayResponseEose;
use swentel\nostr\RelayResponse\RelayResponseEvent;
use swentel\nostr\Request\PersistentConnection;
use swentel\nostr\Request\Request;
use swentel\nostr\Subscription\Subscription;

const EOSE_IDLE_S = 1.0;

function mono(): float
{
    return hrtime(true) / 1e9;
}

function cpu_now(): float
{
    $r = getrusage();
    return $r['ru_utime.tv_sec'] + $r['ru_utime.tv_usec'] / 1e6 + $r['ru_stime.tv_sec'] + $r['ru_stime.tv_usec'] / 1e6;
}

function peak_rss_mb(): ?float
{
    $r = getrusage();
    return isset($r['ru_maxrss']) ? round($r['ru_maxrss'] / 1024, 1) : null; // KiB on Linux
}

/** The current resident set (VmRSS), in MB like peak_rss_mb. */
function rss_mb(): ?float
{
    $s = @file_get_contents('/proc/self/status');
    return ($s !== false && preg_match('/^VmRSS:\s+(\d+)\s+kB/m', $s, $m)) ? round((int) $m[1] / 1024, 1) : null;
}

function pkg_version(string $name): string
{
    return \Composer\InstalledVersions::isInstalled($name)
        ? ltrim((string) \Composer\InstalledVersions::getPrettyVersion($name), 'v') : '?';
}

// ------------------------------------------------------------------ clients
//
// Licenses: each package's composer.json / LICENSE file (see README.md).

function clients(): array
{
    $ws = fn () => 'phrity/websocket ' . pkg_version('phrity/websocket') . ' (pure PHP, blocking streams)';
    $crypto = fn () => 'paragonie/ecc ' . pkg_version('paragonie/ecc') . ' SchnorrSignature (pure PHP on ext-gmp)';
    $common = 'Nothing is verified by default: the library hands the app RelayResponseEvent objects whose ->event is ' .
        'the json_decode()d stdClass. The harness calls the library\'s Event::verify($stdClass) on each one ' .
        '(field types, id = sha256 of json_encode([0,...], JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE), then the ' .
        'BIP-340 signature via paragonie/ecc) and drops the events it rejects. ';
    return [
        [
            'id' => 'nostr-php-persistent', 'library' => 'swentel/nostr-php', 'package' => 'swentel/nostr-php',
            'license' => 'MIT', 'verify' => 'explicit', 'variant' => false,
            'api' => 'Relay::connect + PersistentConnection(relay, RequestMessage)->onReceive(cb)->transmit()',
            'websocket' => $ws, 'crypto' => $crypto,
            'notes' => $common . 'transmit() blocks in the WebSocket client\'s listen loop and calls onReceive for every ' .
                'frame; the callback pauses the connection on EOSE (the library never stops on its own). ' .
                'PersistentConnection also keeps every RelayResponse in an array for the life of the connection. ' .
                'Teardown ignores the ConnectionFailureException that PersistentConnection::close() throws on some runs ' .
                '(it disconnects, then sends a close frame on the closed connection). Config: the WebSocket client\'s read ' .
                'timeout (default 60 s) is raised to --timeout-ms so a slow download is not cut short; otherwise defaults.',
        ],
        [
            'id' => 'nostr-php-request', 'library' => 'swentel/nostr-php', 'package' => 'swentel/nostr-php',
            'license' => 'MIT', 'verify' => 'explicit', 'variant' => true,
            'api' => 'Relay::connect + Request(relay, RequestMessage)->send() (fetch-all: returns every response after EOSE)',
            'websocket' => $ws, 'crypto' => $crypto,
            'notes' => $common . 'Request::send() reads until EOSE, sends CLOSE, disconnects and returns the responses; ' .
                'EOSE reaches the app when send() returns, and the events are verified after it. Config: Request::setTimeout ' .
                '(default 60 s) raised to --timeout-ms; otherwise defaults.',
        ],
    ];
}

// ------------------------------------------------------------------ counting

final class Tally
{
    public int $accepted = 0;
    public int $ambiguous = 0;
    public int $expired = 0;
    public ?float $lastT = null;
    public ?float $eoseT = null;
    private \GMP $xor;

    public function __construct(private array $ambiguousIds, private array $expiredIds, private int $complete)
    {
        $this->xor = gmp_init(0);
    }

    public function add(string $id): void
    {
        $this->accepted++;
        $this->xor = gmp_xor($this->xor, gmp_init($id, 16));
        if (isset($this->ambiguousIds[$id])) {
            $this->ambiguous++;
        }
        if (isset($this->expiredIds[$id])) {
            $this->expired++;
        }
        $this->lastT = mono();
    }

    public function eose(): void
    {
        $this->eoseT ??= mono();
    }

    public function complete(): bool
    {
        return $this->accepted >= $this->complete;
    }

    public function xorHex(): string
    {
        return str_pad(gmp_strval($this->xor, 16), 64, '0', STR_PAD_LEFT);
    }
}

// ------------------------------------------------------------------ child

function emit(array $rec): void
{
    fwrite(STDOUT, json_encode($rec, JSON_UNESCAPED_SLASHES) . "\n");
    fflush(STDOUT);
}

/** One run of a client. Returns after EOSE (and the delivery that may follow it). */
function run_once(string $client, string $url, int $events, Tally $tally, float $timeoutS): void
{
    $sub = new Subscription();
    $subId = $sub->getId();
    $filter = new Filter();
    $filter->setLimit($events);
    $req = new RequestMessage($subId, [$filter]);
    $verifier = new Event();

    // Setup (untimed): a new Relay (and WebSocket client) per run, connected.
    $relay = new Relay($url);
    $relay->connect();
    $relay->getClient()->setTimeout($timeoutS);
    gc_collect_cycles();
    if ($GLOBALS['base_rss_due'] ?? false) {
        // base_rss_mb: the end of the row's first setup (after the collection above), before the REQ
        $GLOBALS['base_rss_due'] = false;
        emit(['type' => 'base', 'base_rss_mb' => rss_mb()]);
    }

    if ($client === 'nostr-php-persistent') {
        $conn = new PersistentConnection($relay, $req);
        $conn->onReceive(function ($resp) use ($tally, $subId, $verifier, $conn) {
            if ($resp instanceof RelayResponseEvent) {
                if ($resp->subscriptionId !== $subId) {
                    return;
                }
                if ($verifier->verify($resp->event)) {
                    $tally->add($resp->event->id);
                }
            } elseif ($resp instanceof RelayResponseEose && $resp->subscriptionId === $subId) {
                $tally->eose();
                $conn->pause();
            }
        });
        $GLOBALS['t0'] = mono();
        $GLOBALS['c0'] = cpu_now();
        $conn->transmit();
        $GLOBALS['c1'] = cpu_now();
        if ($tally->eoseT === null) {
            throw new RuntimeException('transmit() returned without EOSE');
        }
        try {
            $conn->close(); // teardown, untimed
        } catch (\WebSocket\Exception\Exception $e) {
            // close() disconnects and then sends a close frame on the closed connection; on some runs
            // phrity/websocket throws ConnectionFailureException for that. The run itself is complete.
        }
        return;
    }

    // nostr-php-request
    $request = new Request($relay, $req);
    $request->setTimeout($timeoutS);
    $GLOBALS['t0'] = mono();
    $GLOBALS['c0'] = cpu_now();
    $result = $request->send();
    $responses = $result[$url] ?? [];
    foreach ($responses as $resp) {
        if (is_array($resp) && ($resp[0] ?? null) === 'ERROR') {
            throw new RuntimeException('Request::send: ' . ($resp[3] ?? 'error'));
        }
        if ($resp instanceof RelayResponseEose && $resp->subscriptionId === $subId) {
            $tally->eose();
        }
    }
    if ($tally->eoseT === null) {
        throw new RuntimeException('Request::send() returned without EOSE');
    }
    foreach ($responses as $resp) {
        if ($resp instanceof RelayResponseEvent && $resp->subscriptionId === $subId && $verifier->verify($resp->event)) {
            $tally->add($resp->event->id);
        }
    }
    $GLOBALS['c1'] = cpu_now();
}

function child_main(array $o): never
{
    $client = null;
    foreach (clients() as $c) {
        if ($c['id'] === $o['child']) {
            $client = $c;
        }
    }
    if ($client === null) {
        emit(['type' => 'error', 'error' => "unknown client {$o['child']}"]);
        exit(2);
    }
    try {
        $manifest = json_decode(file_get_contents($o['corpus'] . '/manifest.json'), true, flags: JSON_THROW_ON_ERROR);
        $w = null;
        foreach ($manifest['workloads'] as $x) {
            if ($x['name'] === $o['workload']) {
                $w = $x;
            }
        }
        if ($w === null) {
            throw new RuntimeException("unknown workload {$o['workload']}");
        }
        $amb = array_fill_keys($w['ambiguous_ids'], true);
        $exp = array_fill_keys($w['expired_ids'] ?? [], true);
        $complete = $w['valid_events'] + count($amb);
        $url = rtrim($o['relay'], '/') . '/' . $w['name'];
        emit(['type' => 'meta', 'version' => pkg_version($client['package']), 'websocket' => ($client['websocket'])(),
            'crypto' => ($client['crypto'])()]);

        $timeoutS = $o['timeout_ms'] / 1000;
        $warm = $o['warmup_runs'];
        $measured = 0;
        $measuredStart = null;
        pcntl_async_signals(true);
        $GLOBALS['base_rss_due'] = true;
        for ($i = 0; ; $i++) {
            $tally = new Tally($amb, $exp, $complete);
            $GLOBALS['tally'] = $tally;
            $GLOBALS['t0'] = null;
            // The per-run timeout: SIGALRM reports how far the run got and ends the child.
            pcntl_signal(SIGALRM, function () use ($o, $i, $tally) {
                $t0 = $GLOBALS['t0'] ?? mono();
                $us = (mono() - $t0) * 1e6 / max($tally->accepted, 1);
                emit(['type' => 'error', 'run' => $i, 'accepted' => $tally->accepted, 'peak_rss_mb' => peak_rss_mb(),
                    'error' => "timeout: no EOSE within {$o['timeout_ms']} ms ({$tally->accepted} events accepted by then, " .
                        round($us) . ' us per accepted event)']);
                exit(3);
            });
            pcntl_alarm((int) ceil($timeoutS) + 1);
            run_once($client['id'], $url, $w['events'], $tally, $timeoutS);
            // EOSE seen; wait for a complete set or 1 s without events (single-threaded: no-op).
            while (!$tally->complete() && mono() - ($tally->lastT ?? $tally->eoseT) < EOSE_IDLE_S) {
                usleep(10000);
            }
            pcntl_alarm(0);
            $tEnd = max($tally->eoseT, $tally->lastT ?? 0.0);
            $ms = ($tEnd - $GLOBALS['t0']) * 1000;
            emit(['type' => 'run', 'run' => $i, 'warmup' => $i < $warm, 'ms' => round($ms, 3),
                'cpu_ms' => round(($GLOBALS['c1'] - $GLOBALS['c0']) * 1000, 3), 'accepted' => $tally->accepted,
                'accepted_xor' => $tally->xorHex(), 'ambiguous_accepted' => $tally->ambiguous,
                'expired_accepted' => $tally->expired]);
            unset($tally, $GLOBALS['tally']);
            if ($i + 1 <= $warm) {
                continue;
            }
            $measuredStart ??= $GLOBALS['t0'];
            $measured++;
            if ($measured >= $o['max_runs']) {
                break;
            }
            if ($measured >= $o['min_runs'] && (mono() - $measuredStart) * 1000 >= $o['min_time_ms']) {
                break;
            }
        }
        emit(['type' => 'done', 'peak_rss_mb' => peak_rss_mb()]);
        exit(0);
    } catch (Throwable $e) {
        emit(['type' => 'error', 'error' => substr(get_class($e) . ': ' . $e->getMessage(), 0, 500),
            'peak_rss_mb' => peak_rss_mb()]);
        exit(2);
    }
}

// ------------------------------------------------------------------ orchestrator

function median(array $a): float
{
    sort($a);
    $n = count($a);
    return $n % 2 ? (float) $a[intdiv($n, 2)] : ($a[$n / 2 - 1] + $a[$n / 2]) / 2;
}

function percentile(array $a, float $p): float
{
    sort($a);
    return (float) $a[max((int) ceil($p / 100 * count($a)) - 1, 0)];
}

function xor_of(array $ids): \GMP
{
    $x = gmp_init(0);
    foreach ($ids as $id) {
        $x = gmp_xor($x, gmp_init($id, 16));
    }
    return $x;
}

function run_child(array $client, array $w, array $o): array
{
    $cmd = [PHP_BINARY, __FILE__, '--child', $client['id'], '--workload', $w['name'], '--relay', $o['relay'],
        '--corpus', $o['corpus'], '--warmup-runs', (string) $o['warmup_runs'], '--min-runs', (string) $o['min_runs'],
        '--min-time-ms', (string) $o['min_time_ms'], '--max-runs', (string) $o['max_runs'],
        '--timeout-ms', (string) $o['timeout_ms']];
    $proc = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);
    $lines = [];
    $killErr = null;
    $buf = '';
    $perLine = $o['timeout_ms'] / 1000 + 60;
    $deadline = mono() + $perLine;
    $open = [1 => $pipes[1], 2 => $pipes[2]];
    while ($open) {
        $left = $deadline - mono();
        if ($left <= 0) {
            $killErr = 'killed: no progress within ' . round($perLine) . ' s';
            proc_terminate($proc, 9);
            break;
        }
        $r = array_values($open);
        $wr = $ex = null;
        if (stream_select($r, $wr, $ex, (int) $left, (int) (fmod($left, 1) * 1e6)) === false) {
            break;
        }
        foreach ($r as $s) {
            $chunk = fread($s, 65536);
            $fd = $s === $pipes[1] ? 1 : 2;
            if ($chunk === '' || $chunk === false) {
                if (feof($s)) {
                    unset($open[$fd]);
                }
                continue;
            }
            if ($fd === 2) {
                fwrite(STDERR, '   [' . $client['id'] . '] ' . substr($chunk, 0, 400) . "\n");
                continue;
            }
            $buf .= $chunk;
            while (($nl = strpos($buf, "\n")) !== false) {
                $line = trim(substr($buf, 0, $nl));
                $buf = substr($buf, $nl + 1);
                if ($line === '') {
                    continue;
                }
                $rec = json_decode($line, true);
                if (!is_array($rec) || !isset($rec['type'])) {
                    fwrite(STDERR, '   [' . $client['id'] . '] ' . substr($line, 0, 400) . "\n");
                    continue;
                }
                $lines[] = $rec;
                $deadline = mono() + $perLine;
                if ($rec['type'] === 'run') {
                    fwrite(STDERR, sprintf("   %s/%s: run %d%s %.1f ms, cpu %.1f ms, accepted %d\n", $client['id'],
                        $w['name'], $rec['run'], $rec['warmup'] ? ' (warm-up)' : '', $rec['ms'], $rec['cpu_ms'],
                        $rec['accepted']));
                } elseif ($rec['type'] === 'error') {
                    fwrite(STDERR, "   {$client['id']}/{$w['name']}: {$rec['error']}\n");
                }
            }
        }
    }
    foreach ($pipes as $p) {
        fclose($p);
    }
    $status = proc_close($proc);
    return [$lines, $killErr, $status];
}

function build_row(array $client, array $w, array $lines, ?string $killErr, int $status): array
{
    $pick = fn (string $t) => array_values(array_filter($lines, fn ($l) => $l['type'] === $t));
    $meta = $pick('meta')[0] ?? [];
    $runs = $pick('run');
    $errorLine = $pick('error')[0] ?? null;
    $done = $pick('done')[0] ?? null;
    $row = [
        'client' => $client['id'], 'library' => $client['library'], 'version' => $meta['version'] ?? '?',
        'license' => $client['license'], 'api' => $client['api'], 'websocket' => $meta['websocket'] ?? '?',
        'crypto' => $meta['crypto'] ?? '?', 'verify' => $client['verify'], 'notes' => $client['notes'],
        'variant' => $client['variant'], 'workload' => $w['name'], 'events' => $w['events'], 'bytes' => $w['bytes'],
        'accepted' => null, 'accepted_xor' => null, 'ambiguous_accepted' => null, 'expired_accepted' => null,
        'accepted_ok' => false, 'errors' => 0, 'error' => null, 'warmup_runs' => 0, 'runs' => 0,
        'first_run_ms' => null, 'median_ms' => null, 'min_ms' => null, 'p90_ms' => null, 'run_ms' => [],
        'events_per_s' => null, 'us_per_event' => null, 'cpu_ms' => null,
        'peak_rss_mb' => ($done ?? $errorLine ?? [])['peak_rss_mb'] ?? null,
        'base_rss_mb' => $pick('base')[0]['base_rss_mb'] ?? null,
        // PHP has no cumulative allocated-bytes counter (memory_get_usage() is the current heap)
        'alloc_bytes' => null,
    ];
    $first = $runs[0] ?? null;
    if ($first) {
        foreach (['accepted', 'accepted_xor', 'ambiguous_accepted', 'expired_accepted'] as $k) {
            $row[$k] = $first[$k];
        }
        $expIds = $w['expired_ids'] ?? [];
        $ambIds = $w['ambiguous_ids'];
        $expN = $first['expired_accepted'];
        $expOk = $expN === 0 || $expN === count($expIds);
        $wantN = $w['valid_events'] - count($expIds) + $expN + $first['ambiguous_accepted'];
        $want = gmp_init($w['valid_id_xor'], 16);
        if ($expN === 0) {
            $want = gmp_xor($want, xor_of($expIds));
        }
        // Subsets of the ambiguous ids with the accepted count (there is one ambiguous id today).
        $got = gmp_init($first['accepted_xor'], 16);
        $xorOk = false;
        $n = count($ambIds);
        for ($mask = 0; $mask < (1 << $n); $mask++) {
            $subset = [];
            for ($b = 0; $b < $n; $b++) {
                if ($mask & (1 << $b)) {
                    $subset[] = $ambIds[$b];
                }
            }
            if (count($subset) === $first['ambiguous_accepted'] && gmp_cmp(gmp_xor($want, xor_of($subset)), $got) === 0) {
                $xorOk = true;
            }
        }
        $row['accepted_ok'] = $expOk && $first['accepted'] === $wantN && $xorOk;
        foreach ($runs as $r) {
            if ($r['accepted'] !== $first['accepted'] || $r['accepted_xor'] !== $first['accepted_xor']) {
                $row['error'] = "run {$r['run']} delivered a different set ({$r['accepted']} events)";
                break;
            }
        }
    }
    $err = $errorLine['error'] ?? $killErr ?? ($done ? null : "child exited without finishing (status $status)");
    $warm = array_values(array_filter($runs, fn ($r) => $r['warmup']));
    $meas = array_values(array_filter($runs, fn ($r) => !$r['warmup']));
    $row['warmup_runs'] = count($warm);
    $row['runs'] = count($meas);
    $row['first_run_ms'] = $first['ms'] ?? null;
    if ($err !== null || $row['error'] !== null) {
        $row['error'] ??= $err;
        $row['errors'] = 1;
        $row['accepted_ok'] = false;
        $row['accepted'] ??= $errorLine['accepted'] ?? null;
        return $row;
    }
    $ms = array_map(fn ($r) => $r['ms'], $meas);
    $med = median($ms);
    $row['run_ms'] = $ms;
    $row['median_ms'] = round($med, 3);
    $row['min_ms'] = min($ms);
    $row['p90_ms'] = percentile($ms, 90);
    $row['events_per_s'] = round($w['events'] / ($med / 1000), 1);
    $row['us_per_event'] = round($med * 1000 / $w['events'], 3);
    $row['cpu_ms'] = round(median(array_map(fn ($r) => $r['cpu_ms'], $meas)), 3);
    return $row;
}

function host_info(): array
{
    $cpu = null;
    $info = @file_get_contents('/proc/cpuinfo');
    if ($info !== false && preg_match('/^model name\s*:\s*(.+)$/m', $info, $m)) {
        $cpu = trim($m[1]);
    }
    $cores = (int) trim((string) @shell_exec('nproc 2>/dev/null')) ?: null;
    return ['cpu' => $cpu ?? php_uname('m'), 'cores' => $cores, 'os' => php_uname('s') . ' ' . php_uname('r')];
}

function runtime(): string
{
    $jit = 'no JIT';
    if (function_exists('opcache_get_status')) {
        $s = @opcache_get_status(false);
        if (is_array($s) && !empty($s['jit']['enabled']) && !empty($s['jit']['on'])) {
            $jit = 'opcache JIT on';
        }
    }
    return 'PHP ' . PHP_VERSION . " (Zend Engine, $jit; ext-gmp " . phpversion('gmp') . ')';
}

function main(array $argv): void
{
    $o = ['relay' => 'ws://127.0.0.1:7777', 'corpus' => '.corpus', 'out' => 'results/php.json', 'workloads' => null,
        'clients' => null, 'warmup_runs' => 2, 'min_runs' => 5, 'min_time_ms' => 10000, 'max_runs' => 30,
        'timeout_ms' => 300000, 'child' => null, 'workload' => null];
    $quick = $list = false;
    $ints = ['--warmup-runs' => 'warmup_runs', '--min-runs' => 'min_runs', '--min-time-ms' => 'min_time_ms',
        '--max-runs' => 'max_runs', '--timeout-ms' => 'timeout_ms'];
    $strs = ['--relay' => 'relay', '--corpus' => 'corpus', '--out' => 'out', '--child' => 'child',
        '--workload' => 'workload'];
    for ($i = 1; $i < count($argv); $i++) {
        $a = $argv[$i];
        if (isset($ints[$a])) {
            $o[$ints[$a]] = (int) $argv[++$i];
        } elseif (isset($strs[$a])) {
            $o[$strs[$a]] = $argv[++$i];
        } elseif ($a === '--workloads' || $a === '--clients') {
            $o[substr($a, 2)] = explode(',', $argv[++$i]);
        } elseif ($a === '--quick') {
            $quick = true;
        } elseif ($a === '--list') {
            $list = true;
        } else {
            fwrite(STDERR, "unknown flag: $a\n");
            exit(2);
        }
    }
    if ($o['child'] !== null) {
        child_main($o);
    }
    if ($list) {
        foreach (clients() as $c) {
            echo $c['id'], "\n";
        }
        return;
    }
    if ($quick) {
        $o['warmup_runs'] = 1;
        $o['min_runs'] = 2;
        $o['min_time_ms'] = 0;
    }
    $o['max_runs'] = max($o['max_runs'], $o['min_runs']);

    $manifest = json_decode(file_get_contents($o['corpus'] . '/manifest.json'), true, flags: JSON_THROW_ON_ERROR);
    $want = $o['workloads'] ?? ['all'];
    $workloads = array_values(array_filter($manifest['workloads'], fn ($w) => in_array($w['name'], $want, true)));
    if (!$workloads) {
        fwrite(STDERR, 'no such workload: ' . implode(',', $want) . "\n");
        exit(2);
    }
    $clients = array_values(array_filter(clients(), fn ($c) => $o['clients'] === null || in_array($c['id'], $o['clients'], true)));
    if (!$clients) {
        fwrite(STDERR, 'no such client: ' . implode(',', $o['clients']) . "\n");
        exit(2);
    }
    $results = [];
    foreach ($clients as $c) {
        foreach ($workloads as $w) {
            fwrite(STDERR, "== php: {$c['id']} / {$w['name']}\n");
            [$lines, $killErr, $status] = run_child($c, $w, $o);
            $row = build_row($c, $w, $lines, $killErr, $status);
            $results[] = $row;
            fwrite(STDERR, '   -> ' . ($row['error'] !== null ? "ERROR {$row['error']}"
                : "median {$row['median_ms']} ms, cpu {$row['cpu_ms']} ms, ok=" . json_encode($row['accepted_ok'])) . "\n");
        }
    }
    $doc = [
        'harness' => 'php', 'language' => 'PHP', 'runtime' => runtime(), 'host' => host_info(),
        'settings' => ['warmup_runs' => $o['warmup_runs'], 'min_runs' => $o['min_runs'],
            'min_time_ms' => $o['min_time_ms'], 'max_runs' => $o['max_runs'], 'timeout_ms' => $o['timeout_ms']],
        'relay' => $o['relay'], 'corpus_fingerprint' => $manifest['fingerprint'], 'results' => $results,
    ];
    @mkdir(dirname($o['out']), 0777, true);
    file_put_contents($o['out'], json_encode($doc, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n");
    fwrite(STDERR, "wrote {$o['out']}\n");
}

main($argv);
