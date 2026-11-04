# frozen_string_literal: true

# nostrLibBench Ruby harness. Contract: ../HARNESS.md. Run through ./run.sh.
#
# Without --child this script is the orchestrator: for every client and workload it starts
# itself again in a fresh `ruby` process (`--child <client> --workload <w>`), reads one JSON
# line per run from it (with a deadline, so a hung library is killed and still gets a row)
# and writes results/ruby.json. The child puts only its own library on the load path
# (Bundler.setup with that client's groups), opens the subscription, counts what the
# library delivers and reports each run.

# A child puts its client's gems on the load path before anything else is required (json
# is a default gem: loading the stdlib copy first would clash with the locked one).
CHILD_GROUPS = {
  'nostr-client' => %i[nostr], 'nostr_ruby-client' => %i[nostr_ruby],
  'nostrb-client' => %i[nostrb], 'nostrb-fast' => %i[nostrb fast]
}.freeze
if (ci = ARGV.index('--child'))
  begin
    require 'bundler'
    Bundler.setup(:default, *CHILD_GROUPS.fetch(ARGV[ci + 1]))
  rescue StandardError, ScriptError => e
    $stdout.puts(%({"type":"error","error":#{"Bundler.setup: #{e.class}: #{e.message}"[0, 400].inspect}}))
    exit!(2)
  end
end

require 'json'
require 'optparse'
require 'etc'
require 'digest'
require 'securerandom'

HERE = __dir__
ROOT = File.expand_path('..', HERE)
EOSE_IDLE_S = 1.0

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def cpu_now = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)

def gem_version(name)
  spec = Gem.loaded_specs[name]
  spec ? spec.version.to_s : '?'
end

# ------------------------------------------------------------------ clients
#
# CHILD_GROUPS (top) names the Gemfile groups each child puts on its load path. `meta` runs in the child
# after the library is loaded and fills in the resolved versions. `run` is the client
# class (below). Licenses: each gem's LICENSE file / gemspec (see README.md).

CLIENTS = [
  {
    id: 'nostr-client', library: 'nostr', gem: 'nostr', license: 'MIT',
    api: 'Nostr::Client#connect(Relay) + #subscribe(filter:) + on(:message) (wilsonsilva/nostr)',
    verify: 'explicit', variant: false,
    websocket: -> { "faye-websocket #{gem_version('faye-websocket')} on EventMachine #{gem_version('eventmachine')} (C++ reactor)" },
    crypto: -> { "bip-schnorr #{gem_version('bip-schnorr')} + ecdsa_ext #{gem_version('ecdsa_ext')} (pure Ruby)" },
    notes: 'The client hands the app each text frame as a String (on :message) and does nothing else with it: the ' \
           'app JSON.parses the frame and builds a Nostr::Event, as the README does. Nothing is verified by default; ' \
           'the harness calls Event#verify_signature (signature only) and checks the id with the library\'s own ' \
           'Nostr::Crypto#hash_event (private; SHA-256 of JSON.dump(event.serialize)). Config: Client.new(logger: nil) ' \
           '(the default ColorLogger prints every frame to the console). verify_signature raises ' \
           'Schnorr::InvalidSignatureError on "sig":"" instead of returning false (counted as rejected). Client has ' \
           'no disconnect: teardown unsubscribes and stops the process-global EventMachine reactor; the next run\'s ' \
           'connect starts a new one.'
  },
  {
    id: 'nostr_ruby-client', library: 'nostr_ruby', gem: 'nostr_ruby', license: 'MIT',
    api: 'Nostr::Client.new(relay:) + #connect + #subscribe(filter:) + on(:event)/on(:eose) (dtonon/nostr-ruby)',
    verify: 'harness', variant: false,
    websocket: -> { "faye-websocket #{gem_version('faye-websocket')} on EventMachine #{gem_version('eventmachine')} (C++ reactor)" },
    crypto: -> { "bip-schnorr #{gem_version('bip-schnorr')} + ecdsa_ext #{gem_version('ecdsa_ext')} (pure Ruby)" },
    notes: 'The client parses frames into Nostr::Event (Event.from_message, which checks field types only) but has ' \
           'no verify function at all: it signs with bip-schnorr and never verifies. The harness verifies with the ' \
           'library\'s own crypto dependency: id = SHA-256 of JSON.dump(event.serialize) (the library\'s ' \
           'serialize), signature with Schnorr.valid_sig? (bip-schnorr). on(:event) fires for every subscription ' \
           '(the event carries no subscription id). Config: defaults.'
  },
  {
    id: 'nostrb-client', library: 'nostrb', gem: 'nostrb', license: 'LGPL-2.1-only',
    api: 'Nostrb::Client#subscribe(filter) { |event_hash| } (blocks until EOSE; rickhull/nostrb)',
    verify: 'explicit', variant: false,
    websocket: -> { "async-websocket #{gem_version('async-websocket')} (async #{gem_version('async')}, fibers)" },
    crypto: -> { "schnorr_sig #{gem_version('schnorr_sig')} pure (ecdsa_ext #{gem_version('ecdsa_ext')} / ecdsa #{gem_version('ecdsa')}, pure Ruby)" },
    notes: 'Default configuration (stdlib json, pure-Ruby schnorr_sig; nostrb-fast is the documented fast ' \
           'one). subscribe yields each event as a plain Hash (JSON.parse with the gem\'s NIP-01 options) and ' \
           'verifies nothing. The harness calls the library\'s ' \
           'Nostrb::SignedEvent.validate! + SignedEvent.verify(check_id: true) (signature, then id) and drops ' \
           'events that raise (validate! then verify is the order the gem\'s own Relay uses). validate! caps a tag ' \
           'at 99 values (Nostrb.tags!), so it drops one valid event of the corpus (kind 9734 zap request ' \
           'eff6ff2f..., a 104-value relays tag): accepted_ok is false for that reason. subscribe connects lazily, so the WebSocket handshake is inside the timed part, ' \
           'and EOSE reaches the app when subscribe returns. The gem does not declare its async-websocket ' \
           'dependency (Gemfile adds it). Config: CONSOLE_LEVEL=error silences async-pool\'s per-connection ' \
           '"Attempt to unlock a mutex which is not locked" warning on close.'
  },
  {
    id: 'nostrb-fast', library: 'nostrb', gem: 'nostrb', license: 'LGPL-2.1-only',
    api: 'Nostrb::Client#subscribe(filter) { |event_hash| } (blocks until EOSE; rickhull/nostrb)',
    verify: 'explicit', variant: false,
    websocket: -> { "async-websocket #{gem_version('async-websocket')} (async #{gem_version('async')}, fibers)" },
    crypto: lambda {
      lib = (`pkg-config --modversion libsecp256k1 2>/dev/null`.strip rescue '')
      "libsecp256k1 #{lib.empty? ? '(system)' : lib} (C, system library, via rbsecp256k1 #{gem_version('rbsecp256k1')}; schnorr_sig #{gem_version('schnorr_sig')} fast path)"
    },
    notes: -> { "nostrb at its documented fastest: the optional gems it lists (Nostrb::Optional::GEMS) installed, " \
                "rbsecp256k1 #{gem_version('rbsecp256k1')} (schnorr_sig switches to libsecp256k1, its documented \"fast\" " \
                "implementation) and oj #{gem_version('oj')} (nostrb.rb uses Oj for parse and for the id serialization " \
                'when it loads). Otherwise as nostrb-client: SignedEvent.validate! + verify(check_id: true) by the ' \
                'harness, the 99-value tag cap drops one valid event of all. rbsecp256k1 is built against the system ' \
                'libsecp256k1 (libsecp256k1-dev), since its bundled source download is unavailable here. Config: ' \
                'CONSOLE_LEVEL=error (see nostrb-client).' }
  }
].freeze

# ------------------------------------------------------------------ counting

# What the app does with each event the library delivers: count it and XOR its id.
class Tally
  attr_reader :accepted, :ambiguous, :expired, :last_t, :eose_t

  def initialize(ambiguous_ids, expired_ids, complete)
    @ambiguous_ids = ambiguous_ids
    @expired_ids = expired_ids
    @complete = complete
    @accepted = 0
    @ambiguous = 0
    @expired = 0
    @xor = 0
    @last_t = nil
    @eose_t = nil
    @mutex = Mutex.new
    @cond = ConditionVariable.new
  end

  def add(id)
    @accepted += 1
    @xor ^= id.to_i(16)
    @ambiguous += 1 if @ambiguous_ids.include?(id)
    @expired += 1 if @expired_ids.include?(id)
    @last_t = mono
  end

  def eose!
    t = mono
    @mutex.synchronize do
      @eose_t ||= t
      @cond.broadcast
    end
  end

  def xor_hex = format('%064x', @xor)
  def complete? = @accepted >= @complete

  # Waits for EOSE, then for the accepted set to be complete or for 1 s without events.
  # Returns false on timeout.
  def wait(deadline)
    @mutex.synchronize do
      while @eose_t.nil?
        left = deadline - mono
        return false if left <= 0

        @cond.wait(@mutex, [left, 0.05].min)
      end
    end
    until complete?
      idle_since = @last_t || @eose_t
      break if mono - idle_since >= EOSE_IDLE_S
      return false if mono > deadline

      sleep 0.01
    end
    true
  end
end

class RunTimeout < StandardError
  attr_reader :tally

  def initialize(msg, tally)
    super(msg)
    @tally = tally
  end
end

# ------------------------------------------------------------------ client drivers

# wilsonsilva/nostr
class NostrGemDriver
  def initialize(url, events)
    require 'nostr'
    require 'eventmachine'
    @url = url
    @events = events
    @crypto = Nostr::Crypto.new
  end

  def setup(tally)
    @client = Nostr::Client.new(logger: nil)
    opened = Queue.new
    @client.on(:connect) { |_relay| opened << :open }
    @client.on(:error) { |msg| opened << "error: #{msg}" }
    crypto = @crypto
    # event_emitter instance_execs listeners on the client, so no ivars inside the block.
    # The subscription id is chosen here (as the gem's default does, SecureRandom.hex) and passed
    # to subscribe, so the listener knows it before the REQ is sent.
    sub = @sub = [SecureRandom.hex]
    @client.on(:message) do |data|
      msg = JSON.parse(data)
      case msg[0]
      when 'EVENT'
        next unless msg[1] == sub[0]

        h = msg[2]
        ev = Nostr::Event.new(id: h['id'], pubkey: h['pubkey'], created_at: h['created_at'], kind: h['kind'],
                              tags: h['tags'], content: h['content'], sig: h['sig'])
        ok = begin
          crypto.send(:hash_event, ev) == ev.id && ev.verify_signature
        rescue StandardError
          false
        end
        tally.add(ev.id) if ok
      when 'EOSE'
        tally.eose! if msg[1] == sub[0]
      end
    end
    @client.connect(Nostr::Relay.new(url: @url, name: 'blast-relay'))
    r = opened.pop(timeout: 30)
    raise "connect: #{r || 'timeout'}" unless r == :open
  end

  def subscribe
    @client.subscribe(subscription_id: @sub[0], filter: Nostr::Filter.new(limit: @events))
  end

  def teardown
    @client.unsubscribe(@sub[0]) if @sub[0]
    stop_reactor
  end

  def stop_reactor
    return unless EM.reactor_running?

    EM.next_tick { EM.stop }
    t = mono
    sleep 0.005 while EM.reactor_running? && mono - t < 10
  end
end

# dtonon/nostr-ruby
class NostrRubyDriver
  def initialize(url, events)
    require 'nostr_ruby'
    require 'schnorr'
    require 'digest'
    @url = url
    @events = events
  end

  def setup(tally)
    @client = Nostr::Client.new(relay: @url)
    sub = @sub = []
    @client.on(:event) do |ev|
      ok = begin
        Digest::SHA256.hexdigest(JSON.dump(ev.serialize)) == ev.id &&
          Schnorr.valid_sig?([ev.id].pack('H*'), [ev.pubkey].pack('H*'), [ev.sig].pack('H*'))
      rescue StandardError
        false
      end
      tally.add(ev.id) if ok
    end
    @client.on(:eose) { |d| tally.eose! if d.subscription_id == sub[0] }
    @client.connect
  end

  def subscribe
    # The id is set before the REQ goes out (the gem's own default, SecureRandom.hex), so the
    # EOSE listener never sees a frame before it knows the subscription.
    @sub[0] = SecureRandom.hex
    @client.subscribe(subscription_id: @sub[0], filter: Nostr::Filter.new(limit: @events))
  end

  def teardown
    @client.unsubscribe(@sub[0]) if @sub[0]
    @client.close
    t = mono
    sleep 0.005 while EM.reactor_running? && mono - t < 10
  end
end

# rickhull/nostrb
class NostrbDriver
  def initialize(url, events, fast:)
    unless fast
      # Bundler.setup without :fast keeps rbsecp256k1 off the load path; make sure.
      $LOAD_PATH.reject! { |p| p.include?('rbsecp256k1') }
    end
    # async's console logs a harmless 'Attempt to unlock a mutex which is not locked' from the
    # connection pool's gardener task on every close (async-pool 0.12); keep stderr readable.
    ENV['CONSOLE_LEVEL'] ||= 'error'
    require 'nostrb'
    require 'nostrb/client'
    want = fast ? SchnorrSig::Fast : SchnorrSig::Pure
    raise "schnorr_sig picked the wrong implementation (wanted #{want})" unless SchnorrSig.singleton_class.include?(want)
    raise "nostrb JSON: Oj loaded=#{defined?(::Oj) ? true : false}, wanted #{fast}" unless !!defined?(::Oj) == fast

    @url = url
    @events = events
  end

  def setup(tally)
    @tally = tally
    @client = Nostrb::Client.new(@url)
    @filter = Nostrb::Filter.new
    @filter.limit = @events
  end

  # Blocks until EOSE, on the calling thread (the harness adds no thread).
  def subscribe
    tally = @tally
    @client.subscribe(@filter) do |h|
      ok = begin
        Nostrb::SignedEvent.verify(Nostrb::SignedEvent.validate!(h), check_id: true)
        true
      rescue StandardError
        false
      end
      tally.add(h['id']) if ok
    end
    tally.eose!
  end

  def teardown; end
end

# ------------------------------------------------------------------ child

def peak_rss_mb
  hwm = File.read('/proc/self/status')[/^VmHWM:\s+(\d+)\s+kB/, 1]
  hwm ? (hwm.to_i / 1024.0).round(1) : nil
rescue StandardError
  nil
end

def child_main(opts)
  client = CLIENTS.find { |c| c[:id] == opts[:child] } or abort "unknown client #{opts[:child]}"
  out = $stdout
  out.sync = true
  emit = ->(h) { out.puts(JSON.generate(h)) }

  manifest = JSON.parse(File.read(File.join(opts[:corpus], 'manifest.json')))
  w = manifest['workloads'].find { |x| x['name'] == opts[:workload] } or abort "unknown workload #{opts[:workload]}"
  amb = w['ambiguous_ids'].to_set
  exp = (w['expired_ids'] || []).to_set
  complete = w['valid_events'] + amb.size
  url = "#{opts[:relay].chomp('/')}/#{w['name']}"

  driver = case client[:id]
           when 'nostr-client' then NostrGemDriver.new(url, w['events'])
           when 'nostr_ruby-client' then NostrRubyDriver.new(url, w['events'])
           when 'nostrb-client' then NostrbDriver.new(url, w['events'], fast: false)
           when 'nostrb-fast' then NostrbDriver.new(url, w['events'], fast: true)
           end
  emit.call(type: 'meta', version: gem_version(client[:gem]), websocket: client[:websocket].call,
            crypto: client[:crypto].call, notes: client[:notes].respond_to?(:call) ? client[:notes].call : client[:notes])

  timeout_s = opts[:timeout_ms] / 1000.0
  warm = opts[:warmup_runs]
  measured = 0
  measured_start = nil
  i = 0
  loop do
    tally = Tally.new(amb, exp, complete)
    driver.setup(tally)
    GC.start
    # The per-run timeout: a sleeping watchdog (no work of its own) that reports how far the
    # run got and ends the child. Drivers whose subscribe call blocks run it on this thread.
    cancel = Queue.new
    started = mono
    run_i = i
    watchdog = Thread.new do
      next if cancel.pop(timeout: timeout_s)

      emit.call(type: 'error', run: run_i,
                error: "timeout: no EOSE within #{opts[:timeout_ms]} ms " \
                       "(#{tally.accepted} events accepted by then, " \
                       "#{((mono - started) * 1e6 / [tally.accepted, 1].max).round} us per accepted event)",
                accepted: tally.accepted, peak_rss_mb: peak_rss_mb)
      out.flush
      exit!(3)
    end
    c0 = cpu_now
    t0 = mono
    driver.subscribe
    tally.wait(t0 + timeout_s + 5) or sleep # the watchdog ends the process
    c1 = cpu_now
    cancel << true
    watchdog.join
    t_end = [tally.eose_t, tally.last_t].compact.max
    driver.teardown
    emit.call(type: 'run', run: i, warmup: i < warm, ms: ((t_end - t0) * 1000).round(3),
              cpu_ms: ((c1 - c0) * 1000).round(3), accepted: tally.accepted, accepted_xor: tally.xor_hex,
              ambiguous_accepted: tally.ambiguous, expired_accepted: tally.expired)
    i += 1
    next if i <= warm

    measured_start ||= t0
    measured += 1
    break if measured >= opts[:max_runs]
    break if measured >= opts[:min_runs] && (mono - measured_start) * 1000 >= opts[:min_time_ms]
  end
  emit.call(type: 'done', peak_rss_mb: peak_rss_mb)
  out.flush
  exit!(0)
rescue StandardError, ScriptError => e
  $stdout.puts(JSON.generate(type: 'error', error: "#{e.class}: #{e.message}"[0, 500], peak_rss_mb: peak_rss_mb))
  $stdout.flush
  exit!(2)
end

# ------------------------------------------------------------------ orchestrator

def median(a)
  s = a.sort
  n = s.size
  n.odd? ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
end

def percentile(a, p)
  s = a.sort
  s[[((p / 100.0) * s.size).ceil - 1, 0].max]
end

def xor_ids(hex, ids)
  ids.reduce(hex.to_i(16)) { |acc, id| acc ^ id.to_i(16) }
end

def run_child(client, w, opts)
  cmd = [RbConfig.ruby, __FILE__, '--child', client[:id], '--workload', w['name'],
         '--relay', opts[:relay], '--corpus', opts[:corpus],
         '--warmup-runs', opts[:warmup_runs].to_s, '--min-runs', opts[:min_runs].to_s,
         '--min-time-ms', opts[:min_time_ms].to_s, '--max-runs', opts[:max_runs].to_s,
         '--timeout-ms', opts[:timeout_ms].to_s]
  lines = []
  err = nil
  io = IO.popen(cmd, 'r', err: [:child, :out])
  buf = +''
  # One line per run is due within the per-run timeout plus slack for setup/teardown.
  per_line = opts[:timeout_ms] / 1000.0 + 60
  deadline = mono + per_line
  loop do
    left = deadline - mono
    if left <= 0
      err = "killed: no progress within #{per_line.round} s"
      Process.kill('KILL', io.pid) rescue nil
      break
    end
    ready = IO.select([io], nil, nil, left)
    next unless ready

    chunk = begin
      io.read_nonblock(65_536)
    rescue IO::WaitReadable
      next
    rescue EOFError
      break
    end
    buf << chunk
    while (nl = buf.index("\n"))
      line = buf.slice!(0..nl).strip
      next if line.empty?

      rec = (JSON.parse(line) rescue nil)
      if rec.is_a?(Hash) && rec['type']
        lines << rec
        deadline = mono + per_line
        warn "   #{client[:id]}/#{w['name']}: run #{rec['run']}#{rec['warmup'] ? ' (warm-up)' : ''} #{rec['ms']} ms, cpu #{rec['cpu_ms']} ms, accepted #{rec['accepted']}" if rec['type'] == 'run'
        warn "   #{client[:id]}/#{w['name']}: #{rec['error']}" if rec['type'] == 'error'
      else
        warn "   [#{client[:id]}] #{line}"
      end
    end
  end
  io.close rescue nil
  status = $?
  [lines, err, status]
end

def build_row(client, w, lines, kill_err, status)
  meta = lines.find { |l| l['type'] == 'meta' } || {}
  runs = lines.select { |l| l['type'] == 'run' }
  error_line = lines.find { |l| l['type'] == 'error' }
  done = lines.find { |l| l['type'] == 'done' }
  row = {
    client: client[:id], library: client[:library], version: meta['version'] || '?', license: client[:license],
    api: client[:api], websocket: meta['websocket'] || '?', crypto: meta['crypto'] || '?', verify: client[:verify],
    notes: meta['notes'] || (client[:notes].is_a?(String) ? client[:notes] : ''), variant: client[:variant], workload: w['name'], events: w['events'], bytes: w['bytes'],
    accepted: nil, accepted_xor: nil, ambiguous_accepted: nil, expired_accepted: nil, accepted_ok: false,
    errors: 0, error: nil, warmup_runs: 0, runs: 0, first_run_ms: nil, median_ms: nil, min_ms: nil, p90_ms: nil,
    run_ms: [], events_per_s: nil, us_per_event: nil, cpu_ms: nil,
    peak_rss_mb: (done || error_line || {})['peak_rss_mb']
  }
  first = runs.first
  if first
    row[:accepted] = first['accepted']
    row[:accepted_xor] = first['accepted_xor']
    row[:ambiguous_accepted] = first['ambiguous_accepted']
    row[:expired_accepted] = first['expired_accepted']
    exp_ids = w['expired_ids'] || []
    amb_ids = w['ambiguous_ids']
    exp_n = first['expired_accepted']
    exp_ok = exp_n.zero? || exp_n == exp_ids.size
    want_n = w['valid_events'] - exp_ids.size + exp_n + first['ambiguous_accepted']
    # The XOR of the dropped expired ids and accepted ambiguous ids must be the expected set's.
    got = first['accepted_xor'].to_i(16)
    want = w['valid_id_xor'].to_i(16)
    want ^= exp_ids.reduce(0) { |a, id| a ^ id.to_i(16) } if exp_n.zero?
    # Which ambiguous ids it took is fixed by the count only when there is at most one.
    amb_combos = (0..amb_ids.size).flat_map { |k| amb_ids.combination(k).to_a }
                                  .select { |c| c.size == first['ambiguous_accepted'] }
    xor_ok = amb_combos.any? { |c| (want ^ c.reduce(0) { |a, id| a ^ id.to_i(16) }) == got }
    row[:accepted_ok] = exp_ok && first['accepted'] == want_n && xor_ok
    bad = runs.find { |r| r['accepted'] != first['accepted'] || r['accepted_xor'] != first['accepted_xor'] }
    row[:error] = "run #{bad['run']} delivered a different set (#{bad['accepted']} events)" if bad
  end
  err = error_line && error_line['error']
  err ||= kill_err
  err ||= (done ? nil : "child exited without finishing (status #{status&.exitstatus.inspect})")
  if err || row[:error]
    row[:error] ||= err
    row[:errors] = 1
    row[:accepted_ok] = false
    row[:accepted] ||= error_line && error_line['accepted']
    row[:warmup_runs] = runs.count { |r| r['warmup'] }
    row[:runs] = runs.count { |r| !r['warmup'] }
    row[:first_run_ms] = first && first['ms']
    return row
  end
  warm = runs.select { |r| r['warmup'] }
  meas = runs.reject { |r| r['warmup'] }
  ms = meas.map { |r| r['ms'] }
  row[:warmup_runs] = warm.size
  row[:runs] = meas.size
  row[:first_run_ms] = runs.first['ms']
  row[:run_ms] = ms
  med = median(ms)
  row[:median_ms] = med.round(3)
  row[:min_ms] = ms.min
  row[:p90_ms] = percentile(ms, 90)
  row[:events_per_s] = (w['events'] / (med / 1000.0)).round(1)
  row[:us_per_event] = (med * 1000.0 / w['events']).round(3)
  row[:cpu_ms] = median(meas.map { |r| r['cpu_ms'] }).round(3)
  row
end

def host_info
  cpu = File.read('/proc/cpuinfo')[/^model name\s*:\s*(.+)$/, 1] rescue nil
  u = Etc.uname
  { cpu: cpu || u[:machine], cores: Etc.nprocessors, os: "#{u[:sysname]} #{u[:release]}" }
end

def runtime
  jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enabled?) && RubyVM::YJIT.enabled? ? 'YJIT on' : 'no JIT'
  "CRuby #{RUBY_VERSION} (#{jit})"
end

def main
  opts = { relay: 'ws://127.0.0.1:7777', corpus: '.corpus', out: 'results/ruby.json', workloads: nil, clients: nil,
           warmup_runs: 2, min_runs: 5, min_time_ms: 10_000, max_runs: 30, timeout_ms: 300_000 }
  quick = false
  list = false
  OptionParser.new do |o|
    o.on('--relay URL') { |v| opts[:relay] = v }
    o.on('--corpus DIR') { |v| opts[:corpus] = v }
    o.on('--out FILE') { |v| opts[:out] = v }
    o.on('--workloads LIST') { |v| opts[:workloads] = v.split(',') }
    o.on('--workload NAME') { |v| opts[:workload] = v }
    o.on('--clients LIST') { |v| opts[:clients] = v.split(',') }
    o.on('--warmup-runs N', Integer) { |v| opts[:warmup_runs] = v }
    o.on('--min-runs N', Integer) { |v| opts[:min_runs] = v }
    o.on('--min-time-ms N', Integer) { |v| opts[:min_time_ms] = v }
    o.on('--max-runs N', Integer) { |v| opts[:max_runs] = v }
    o.on('--timeout-ms N', Integer) { |v| opts[:timeout_ms] = v }
    o.on('--quick') { quick = true }
    o.on('--list') { list = true }
    o.on('--child ID') { |v| opts[:child] = v }
  end.parse!(ARGV)

  return child_main(opts) if opts[:child]

  if list
    CLIENTS.each { |c| puts c[:id] }
    return
  end
  if quick
    opts[:warmup_runs] = 1
    opts[:min_runs] = 2
    opts[:min_time_ms] = 0
  end
  opts[:max_runs] = [opts[:max_runs], opts[:min_runs]].max

  manifest = JSON.parse(File.read(File.join(opts[:corpus], 'manifest.json')))
  workloads = manifest['workloads'].select { |w| (opts[:workloads] || ['all']).include?(w['name']) }
  abort "no such workload: #{opts[:workloads].inspect}" if workloads.empty?
  clients = CLIENTS.select { |c| opts[:clients].nil? || opts[:clients].include?(c[:id]) }
  abort "no such client: #{opts[:clients].inspect} (have: #{CLIENTS.map { |c| c[:id] }.join(',')})" if clients.empty?

  results = []
  clients.each do |c|
    workloads.each do |w|
      warn "== ruby: #{c[:id]} / #{w['name']}"
      lines, kill_err, status = run_child(c, w, opts)
      row = build_row(c, w, lines, kill_err, status)
      results << row
      summary = row[:error] ? "ERROR #{row[:error]}" : "median #{row[:median_ms]} ms, cpu #{row[:cpu_ms]} ms, ok=#{row[:accepted_ok]}"
      warn "   -> #{summary}"
    end
  end

  doc = {
    harness: 'ruby', language: 'Ruby', runtime: runtime, host: host_info,
    settings: { warmup_runs: opts[:warmup_runs], min_runs: opts[:min_runs], min_time_ms: opts[:min_time_ms],
                max_runs: opts[:max_runs], timeout_ms: opts[:timeout_ms] },
    relay: opts[:relay], corpus_fingerprint: manifest['fingerprint'], results: results
  }
  require 'fileutils'
  FileUtils.mkdir_p(File.dirname(opts[:out]))
  File.write(opts[:out], JSON.pretty_generate(doc) + "\n")
  warn "wrote #{opts[:out]}"
end

require 'set'
main
