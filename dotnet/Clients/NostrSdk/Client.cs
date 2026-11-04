// Nostr.Sdk: rust-nostr's nostr-sdk (Rust) through its UniFFI C# bindings (nostrdevkit/nostr-sdk-ffi).
using LibBench;
using Nostr.Sdk;

public static class Program
{
    public static Task<int> Main(string[] args) => ChildMain.Run(args, [new SdkStream()]);
}

public sealed class SdkStream : BenchClient
{
    public override string Id => "nostr-sdk";
    public override string Library => "Nostr.Sdk (rust-nostr)";
    public override string Package => "Nostr.Sdk";
    public override string License => "MIT";
    public override string Api => "Client.StreamEvents(ReqTarget.Auto([filter]), ExitOnEose) + ClientEventStream.Next(), one relay";
    public override string Websocket => "async-wsocket 0.17 / tokio-tungstenite 0.28 (Rust, in libnostr_sdk_ffi.so)";
    public override string Crypto => "libsecp256k1 (C, via rust secp256k1 0.30 / secp256k1-sys 0.10, in libnostr_sdk_ffi.so)";
    public override string Verify => "library";
    public override string Notes =>
        "Rust library (nostr-sdk 0.45.2, nostr 0.45.3, serde_json) behind UniFFI: every event crosses the FFI " +
        "(a Next() async call per event, the Event object is a handle; its id is read with event.Id().ToHex()). " +
        "The relay pool verifies id and signature of every event before delivering it and drops NIP-40-expired events. " +
        "The stream ends at EOSE (ExitOnEose); its end is the EOSE time. StreamEvents runs through rust-nostr's fixed " +
        "internal channels (the relay's notification broadcast, then the stream's own channel), whose sizes the bindings " +
        "do not expose. Client.AddRelay(url, RelayCapabilities.Read(), ...) (the C# binding takes the capabilities " +
        "explicitly; the Rust default is read + write, and ReqTarget.Auto sends the REQ to read relays either way) + " +
        "Connect are untimed. alloc_bytes counts only the managed side (handles, strings); the Rust heap is not counted.";

    Client? _client;

    public override async Task SetupAsync(Uri url, RunCtx ctx)
    {
        _client = new Client();
        await _client.AddRelay(RelayUrl.Parse(url.ToString()), RelayCapabilities.Read(), false, new RelayOptions());
        await _client.Connect(TimeSpan.FromSeconds(10));
    }

    public override async Task RunAsync(RunCtx ctx)
    {
        var filter = new Filter().Limit((ulong)ctx.Limit);
        ctx.Start();
        var stream = await _client!.StreamEvents(ReqTarget.Auto([filter]), "bench-" + Guid.NewGuid().ToString("N")[..8],
            null, new ReqExitPolicy.ExitOnEose());
        while (await stream.Next() is ClientEventStreamItem item)
        {
            if (item.Event is Event e) ctx.Event(e.Id().ToHex());
            else throw new Exception("stream error item: " + item.Error);
        }
        ctx.Eose();
    }

    public override async Task TeardownAsync()
    {
        try { await _client!.Disconnect(); } catch { }
        _client?.Dispose();
    }
}
