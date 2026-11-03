// Nostra (lontivero/nostra): an F# Nostr library, driven from C# through its F# API.
using LibBench;
using Microsoft.FSharp.Collections;
using Microsoft.FSharp.Core;
using NClient = Nostra.Client;

public static class Program
{
    public static Task<int> Main(string[] args) => ChildMain.Main(args, [new NostraClient()]);
}

public sealed class NostraClient : BenchClient
{
    public override string Id => "nostra";
    public override string Library => "Nostra (F#)";
    public override string Package => "Nostra";
    public override string License => "GPL-2.0-only";
    public override string Api => "Client.ConnectToRelayAsync + Client.StartListening(callback) + Client.Subscribe, one relay";
    public override string Websocket => "System.Net.WebSockets.ClientWebSocket (.NET 10)";
    public override string Crypto => "NBitcoin.Secp256k1 {NBitcoin.Secp256k1} (pure C#)";
    public override string Verify => "library";
    public override string Notes =>
        "F# library used from C#. Its receive loop verifies every EVENT (Event.verify: recomputed id + BIP-340) and hands " +
        "the callback a Result: Ok(RMEvent) for valid events, Error for invalid or undecodable ones (counted as rejected). " +
        "JSON via Thoth.Json.Net {Thoth.Json.Net} (Newtonsoft.Json {Newtonsoft.Json} underneath). License file: GPL-2.0.";

    NClient.RelayClient? _relay;
    Task? _listen;
    string _sub = "";

    public override async Task SetupAsync(Uri url, RunCtx ctx)
    {
        _sub = "bench-" + Guid.NewGuid().ToString("N")[..8];
        _relay = await NClient.ConnectToRelayAsync(url);
        var cb = FuncConvert.FromAction<FSharpResult<NClient.Response.RelayMessage, string>>(r =>
        {
            if (r.IsError) { ctx.Reject(); return; }
            var msg = r.ResultValue;
            if (msg is NClient.Response.RelayMessage.RMEvent ev)
            {
                if (ev.Item1 != _sub) return;
                ctx.Event(Convert.ToHexStringLower(((Nostra.EventIdT)ev.Item2.Id).Item));
            }
            else if (msg is NClient.Response.RelayMessage.RMEOSE eose)
            {
                if (eose.Item == _sub) ctx.Eose();
            }
        });
        _listen = NClient.StartListening(cb, _relay);
    }

    public override Task RunAsync(RunCtx ctx)
    {
        var filter = NClient.Request.Filter.limit(ctx.Limit, NClient.Request.Filter.all);
        ctx.Start();
        NClient.Subscribe(_sub, FSharpList<NClient.SubscriptionFilter>.Cons(filter, FSharpList<NClient.SubscriptionFilter>.Empty), _relay!);
        return Task.CompletedTask;
    }

    public override async Task TeardownAsync()
    {
        try
        {
            await Microsoft.FSharp.Control.FSharpAsync.StartAsTask(_relay!.disconnect.Invoke(CancellationToken.None),
                FSharpOption<TaskCreationOptions>.None, FSharpOption<CancellationToken>.None);
        }
        catch { }
    }
}
