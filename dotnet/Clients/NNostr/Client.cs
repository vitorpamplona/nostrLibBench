// NNostr.Client (Kukks/NNostr).
using LibBench;
using NNostr.Client;

public static class Program
{
    public static Task<int> Main(string[] args) =>
        ChildMain.Run(args, [new NNostrEvents(), new NNostrAsyncEnumerable()]);
}

public abstract class NNostrBase : BenchClient
{
    public override string Library => "NNostr.Client";
    public override string Package => "NNostr.Client";
    public override string License => "MIT";
    public override string Websocket => "System.Net.WebSockets.ClientWebSocket (.NET 10)";
    public override string Crypto => "NBitcoin.Secp256k1 {NBitcoin.Secp256k1} (pure C#)";
    public override string Verify => "library";
    protected const string VerifyNote =
        "The client verifies every event before raising it: NostrExtensions.Verify() recomputes the id " +
        "(its own string-built NIP-01 serialization, SHA-256) and checks the BIP-340 signature; failing events are dropped. " +
        "Frames go through an unbounded Channel to one processing task (System.Text.Json JsonDocument + Deserialize<NostrEvent>).";

    protected NostrClient? Client;

    public override async Task SetupAsync(Uri url, RunCtx ctx)
    {
        Client = new NostrClient(url);
        await Client.ConnectAndWaitUntilConnected();
    }

    public override async Task TeardownAsync()
    {
        try { await Client!.Disconnect(); } catch { }
        Client?.Dispose();
    }
}

public sealed class NNostrEvents : NNostrBase
{
    public override string Id => "nnostr";
    public override string Api => "NostrClient.CreateSubscription + EventsReceived/EoseReceived events, one relay";
    public override string Notes => "ConnectAndWaitUntilConnected (polls the socket state every 100 ms) is untimed. " + VerifyNote;

    public override Task RunAsync(RunCtx ctx)
    {
        var sub = "bench-" + Guid.NewGuid().ToString("N")[..8];
        Client!.EventsReceived += (_, a) =>
        {
            if (a.subscriptionId != sub) return;
            foreach (var e in a.events) ctx.Event(e.Id);
        };
        Client.EoseReceived += (_, s) => { if (s == sub) ctx.Eose(); };
        ctx.Start();
        return Client.CreateSubscription(sub, [new NostrSubscriptionFilter { Limit = ctx.Limit }]);
    }
}

public sealed class NNostrAsyncEnumerable : NNostrBase
{
    public override string Id => "nnostr-subscribeforevents";
    public override bool Variant => true;
    public override string Api => "client.SubscribeForEvents(filters, stopWhenEoseSent: true) (IAsyncEnumerable), one relay";
    public override string Notes =>
        "The enumeration ends at the EOSE; the end of the await foreach is the EOSE time. " + VerifyNote;

    public override async Task RunAsync(RunCtx ctx)
    {
        ctx.Start();
        await foreach (var e in Client!.SubscribeForEvents([new NostrSubscriptionFilter { Limit = ctx.Limit }], true, CancellationToken.None))
            ctx.Event(e.Id);
        ctx.Eose();
    }
}
