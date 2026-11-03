// NostrNet (Galaxoid-Labs/NostrNet): RelayPool and RelayClient from NostrNet.Relay.
using LibBench;
using NostrNet.Relay;

public static class Program
{
    public static Task<int> Main(string[] args) => ChildMain.Main(args, [new NostrNetPool(), new NostrNetRelayClient()]);
}

public abstract class NostrNetBase : BenchClient
{
    public override string Library => "NostrNet";
    public override string Package => "NostrNet.Relay";
    public override string License => "MIT";
    public override string Websocket => "System.Net.WebSockets.ClientWebSocket (.NET 10)";
    public override string Crypto => "NBitcoin.Secp256k1 {NBitcoin.Secp256k1} (pure C#)";
    public override string Verify => "library";
    protected const string VerifyNote =
        "RelayClient verifies every event (NostrEvent.Verify: recomputed id + BIP-340) before it reaches a subscription " +
        "and drops failures silently; frames are parsed with System.Text.Json JsonDocument. " +
        "The top-level NostrClient.SubscribeAsync hides the EOSE, so the harness uses the layer below it, which yields it.";

    protected static async Task Consume(IAsyncEnumerable<SubscriptionEvent> stream, RunCtx ctx)
    {
        await foreach (var msg in stream)
        {
            switch (msg)
            {
                case SubscriptionEventReceived e: ctx.Event(e.Event.Id.ToHex()); break;
                case SubscriptionEndOfStoredEvents: ctx.Eose(); return;
                case SubscriptionClosed c: throw new Exception("subscription closed: " + c.Reason);
            }
        }
    }
}

public sealed class NostrNetPool : NostrNetBase
{
    public override string Id => "nostrnet";
    public override string Api => "RelayPool.ConnectAsync + pool.SubscribeAsync (IAsyncEnumerable<SubscriptionEvent>), one relay";
    public override string Notes => VerifyNote + " Auto-reconnect/resubscribe are the pool's defaults (no reconnect happens).";
    RelayPool? _pool;

    public override async Task SetupAsync(Uri url, RunCtx ctx)
    {
        _pool = new RelayPool();
        var failures = await _pool.ConnectAsync([url]);
        if (failures.Count > 0) throw failures.Values.First();
    }

    public override Task RunAsync(RunCtx ctx)
    {
        ctx.Start();
        return Consume(_pool!.SubscribeAsync("bench-" + Guid.NewGuid().ToString("N")[..8], [new Filter { Limit = ctx.Limit }]), ctx);
    }

    public override async Task TeardownAsync() => await _pool!.DisposeAsync();
}

public sealed class NostrNetRelayClient : NostrNetBase
{
    public override string Id => "nostrnet-relayclient";
    public override bool Variant => true;
    public override string Api => "RelayClient.ConnectAsync + client.SubscribeAsync (IAsyncEnumerable<SubscriptionEvent>), single relay, no pool";
    public override string Notes => VerifyNote;
    RelayClient? _client;

    public override async Task SetupAsync(Uri url, RunCtx ctx)
    {
        _client = new RelayClient();
        await _client.ConnectAsync(url);
    }

    public override Task RunAsync(RunCtx ctx)
    {
        ctx.Start();
        return Consume(_client!.SubscribeAsync("bench-" + Guid.NewGuid().ToString("N")[..8], [new Filter { Limit = ctx.Limit }]), ctx);
    }

    public override async Task TeardownAsync() => await _client!.DisposeAsync();
}
