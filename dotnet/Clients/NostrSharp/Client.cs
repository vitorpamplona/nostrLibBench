// NostrSharp (smaciullator/NostrSharp).
using System.Reflection;
using LibBench;
using NostrSharp.Nostr;
using NostrSharp.Relay;
using NostrSharp.Relay.Models;
using NostrSharp.Relay.Models.Messagges;

public static class Program
{
    public static Task<int> Main(string[] args) => ChildMain.Run(args, [new NostrSharpClient()]);
}

public sealed class NostrSharpClient : BenchClient
{
    public override string Id => "nostrsharp";
    public override string Library => "NostrSharp";
    public override string Package => "NostrSharp";
    public override string License => "MIT";
    public override string Api => "NSRelay.TryConnect + OnEvent/OnEose events + SendFilter(NRequestReq), one relay";
    public override string Websocket => "System.Net.WebSockets.ClientWebSocket (.NET 10)";
    public override string Crypto => "NBitcoin.Secp256k1 {NBitcoin.Secp256k1} (pure C#)";
    public override string Verify => "explicit";
    public override string Notes =>
        "Last release 2023. NSRelay does not verify. Per event the harness calls NEvent.IsVerified() (BIP-340 over the id " +
        "it recomputes with Newtonsoft.Json) and, because IsVerified never compares that id with the event's Id, also the " +
        "library's own id function (the private NEvent.GetId, called by reflection) against Id. " +
        "NSRelay queues frames and its dispatch loop sleeps 200 ms whenever the queue is empty; it splits every frame on ',' " +
        "to find the message type. Its id function re-serializes the event with an empty tag list (`[0,pubkey,created_at,kind,[],content]` for an event that has tags), so only tagless events pass. SendFilter replaces the REQ's subscription id with the relay object's own SubscriptionId (a Guid). TryConnect also fetches NIP-11 over HTTP (untimed).";

    static readonly MethodInfo GetId = typeof(NEvent).GetMethod("GetId", BindingFlags.NonPublic | BindingFlags.Instance)
        ?? throw new MissingMethodException("NEvent.GetId");

    NSRelay? _relay;
    string _sub = "";

    public override async Task SetupAsync(Uri url, RunCtx ctx)
    {
        _sub = "bench-" + Guid.NewGuid().ToString("N")[..8];
        _relay = new NSRelay(new NSRelayConfig(url));
        _relay.OnEvent += (_, resp) =>
        {
            if (resp.SubscriptionId != _relay!.SubscriptionId.ToString()) return;
            var ev = resp.Event;
            bool ok;
            try { ok = ev?.Id != null && ev.IsVerified() && (string?)GetId.Invoke(ev, null) == ev.Id; }
            catch { ok = false; }
            if (ok) ctx.Event(ev!.Id!); else ctx.Reject();
        };
        _relay.OnEose += (_, resp) => { if (resp.SubscriptionId == _relay!.SubscriptionId.ToString()) ctx.Eose(); };
        if (!await _relay.TryConnect()) throw new Exception("NSRelay.TryConnect failed");
    }

    public override async Task RunAsync(RunCtx ctx)
    {
        ctx.Start();
        if (!await _relay!.SendFilter(new NRequestReq(_sub, new NSRelayFilter { Limit = ctx.Limit })))
            throw new Exception("SendFilter failed");
    }

    public override async Task TeardownAsync()
    {
        try { await _relay!.TryDisconnect(); } catch { }
    }
}
