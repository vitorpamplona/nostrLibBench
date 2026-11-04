// NostrSharp (smaciullator/NostrSharp).
using System.Reflection;
using LibBench;
using NostrSharp.Keys;
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
        "Last release 2023. NSRelay does not verify, and NEvent.IsVerified() checks BIP-340 over the id it recomputes (GetId) " +
        "without ever comparing it with the event's Id. So per event the harness calls the library's own id function (the " +
        "private NEvent.GetId, Newtonsoft.Json + SHA-256, by reflection) once, compares it with Id, then checks the " +
        "signature over Id with NPub.FromHex(PubKey).IsHexSignatureValid(Sig, Id), the call IsVerified makes. " +
        "NSRelay queues frames and its dispatch loop sleeps 200 ms whenever the queue is empty; it splits every frame on ',' " +
        "to find the message type. GetId serializes a temporary NEventSign that shares the event's Tags list and disposes it, " +
        "which clears that list: the first id is right, but the event is left without tags and any later GetId (or " +
        "IsVerified) hashes an empty tag list, hence one id computation per event. NTag holds a key and at most 4 values, " +
        "so a valid event with a longer tag (zap-request relays tags, ...) gets a wrong id and is rejected. SendFilter replaces the REQ's subscription id with the relay object's own SubscriptionId (a Guid). TryConnect also fetches NIP-11 over HTTP (untimed).";

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
            // One hash: the library's id function, compared with Id, then IsVerified's own signature check over Id.
            try
            {
                ok = ev?.Id != null && ev.PubKey != null && (string?)GetId.Invoke(ev, null) == ev.Id
                    && NPub.FromHex(ev.PubKey).IsHexSignatureValid(ev.Sig, ev.Id);
            }
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
