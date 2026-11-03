// Nostr.Client (Marfusios/nostr-client) and its fork Blockcore.Nostr.Client: same API and
// namespaces, so one source file serves both projects (BLOCKCORE picks the metadata).
using LibBench;
using Nostr.Client.Client;
using Nostr.Client.Communicator;
using Nostr.Client.Requests;

#if BLOCKCORE
public static class Program
{
    public static Task<int> Main(string[] args) => ChildMain.Main(args, [new MarfusiosClient()]);
}
#else
public static class Program
{
    public static Task<int> Main(string[] args) => ChildMain.Main(args, [new MarfusiosClient()]);
}
#endif

public sealed class MarfusiosClient : BenchClient
{
#if BLOCKCORE
    public override string Id => "blockcore-nostr-client";
    public override string Library => "Blockcore.Nostr.Client";
    public override string Package => "Blockcore.Nostr.Client";
    public override string Notes =>
        "Blockcore's fork of Nostr.Client (adds NIP-44/PoW; same receive path). " + Common;
#else
    public override string Id => "nostr-client";
    public override string Library => "Nostr.Client";
    public override string Package => "Nostr.Client";
    public override string Notes => Common;
#endif
    const string Common =
        "NostrWebsocketClient.Streams.EventStream/EoseStream (Rx) after client.Send(new NostrRequest(sub, filter)). " +
        "The client does not verify: per event the harness calls the library's NostrEvent.ComputeId() " +
        "(re-serializes the event with Newtonsoft.Json) and compares it with Id, then NostrEvent.IsSignatureValid() " +
        "(BIP-340 over Id). Websocket.Client reconnection and its no-message reconnect timeout are turned off.";
    public override string License => "Apache-2.0";
    public override string Api => "NostrWebsocketClient + Streams.EventStream/EoseStream (Rx), one relay";
    public override string Websocket => "Websocket.Client {Websocket.Client} (System.Net.WebSockets.ClientWebSocket)";
    public override string Crypto => "NBitcoin.Secp256k1 {NBitcoin.Secp256k1} (pure C#)";
    public override string Verify => "explicit";

    NostrWebsocketCommunicator? _comm;
    NostrWebsocketClient? _client;
    readonly List<IDisposable> _subs = new();
    string _subId = "";

    public override async Task SetupAsync(Uri url, RunCtx ctx)
    {
        _subId = "bench-" + Guid.NewGuid().ToString("N")[..8];
        _comm = new NostrWebsocketCommunicator(url)
        {
            IsReconnectionEnabled = false,
            ReconnectTimeout = null,
            ErrorReconnectTimeout = null,
        };
        _client = new NostrWebsocketClient(_comm, null);
        _subs.Add(_client.Streams.EventStream.Subscribe(resp =>
        {
            if (resp.Subscription != _subId) return;
            var ev = resp.Event;
            bool ok;
            try { ok = ev?.Id != null && ev.ComputeId() == ev.Id && ev.IsSignatureValid(); }
            catch { ok = false; }
            if (ok) ctx.Event(ev!.Id!); else ctx.Reject();
        }));
        _subs.Add(_client.Streams.EoseStream.Subscribe(resp =>
        {
            if (resp.Subscription == _subId) ctx.Eose();
        }));
        await _comm.StartOrFail();
    }

    public override Task RunAsync(RunCtx ctx)
    {
        ctx.Start();
        _client!.Send(new NostrRequest(_subId, new NostrFilter { Limit = ctx.Limit }));
        return Task.CompletedTask;
    }

    public override async Task TeardownAsync()
    {
        try { _client!.Send(new NostrCloseRequest(_subId)); } catch { }
        foreach (var s in _subs) s.Dispose();
        _subs.Clear();
        _client?.Dispose();
        try { await _comm!.Stop(System.Net.WebSockets.WebSocketCloseStatus.NormalClosure, "bye"); } catch { }
        _comm?.Dispose();
    }
}
