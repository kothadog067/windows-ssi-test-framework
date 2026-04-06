using System.Net;
using System.Text;
using System.Text.Json;

// ---------------------------------------------------------------------------
// Host setup — UseWindowsService() makes this process register itself with
// the Service Control Manager when running as a Windows Service.  When run
// interactively (dev / verify) it behaves like a normal console application.
// ---------------------------------------------------------------------------
IHost host = Host.CreateDefaultBuilder(args)
    .UseWindowsService(options =>
    {
        options.ServiceName = "DDWorkerSvc";
    })
    .ConfigureServices(services =>
    {
        services.AddHostedService<HttpListenerWorker>();
        services.AddHostedService<ComputeWorker>();
    })
    .Build();

await host.RunAsync();

// ===========================================================================
// HttpListenerWorker — serves HTTP on port 8084 via a background thread.
// Using HttpListener (instead of Kestrel) keeps the binary entirely
// self-contained without requiring ASP.NET runtime.
// ===========================================================================
public sealed class HttpListenerWorker : BackgroundService
{
    private readonly ILogger<HttpListenerWorker> _logger;
    private const int Port = 8084;

    public HttpListenerWorker(ILogger<HttpListenerWorker> logger) => _logger = logger;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var listener = new HttpListener();
        listener.Prefixes.Add($"http://+:{Port}/");
        listener.Start();
        _logger.LogInformation("HTTP listener started on port {Port}", Port);

        // The HttpListener API is inherently callback/blocking.  We offload
        // each GetContextAsync call onto the thread pool so the cancellation
        // token is honoured promptly.
        while (!stoppingToken.IsCancellationRequested)
        {
            HttpListenerContext ctx;
            try
            {
                ctx = await listener.GetContextAsync().WaitAsync(stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (HttpListenerException ex)
            {
                _logger.LogWarning("HttpListener error: {Msg}", ex.Message);
                break;
            }

            // Handle each request on the thread pool (fire-and-forget is fine
            // here because each handler is independent).
            _ = Task.Run(() => HandleRequest(ctx), stoppingToken);
        }

        listener.Stop();
        _logger.LogInformation("HTTP listener stopped");
    }

    private void HandleRequest(HttpListenerContext ctx)
    {
        string responseBody;
        int statusCode = 200;

        try
        {
            var path   = ctx.Request.Url?.AbsolutePath ?? "/";
            var method = ctx.Request.HttpMethod.ToUpperInvariant();

            if (path == "/health" && method == "GET")
            {
                responseBody = JsonSerializer.Serialize(new
                {
                    status  = "ok",
                    service = "dd-worker-svc",
                    pid     = Environment.ProcessId
                });
            }
            else
            {
                statusCode   = 404;
                responseBody = JsonSerializer.Serialize(new { error = "not found", path });
            }
        }
        catch (Exception ex)
        {
            statusCode   = 500;
            responseBody = JsonSerializer.Serialize(new { error = ex.Message });
        }

        byte[] buffer = Encoding.UTF8.GetBytes(responseBody);
        ctx.Response.StatusCode  = statusCode;
        ctx.Response.ContentType = "application/json; charset=utf-8";
        ctx.Response.ContentLength64 = buffer.Length;
        try
        {
            ctx.Response.OutputStream.Write(buffer, 0, buffer.Length);
        }
        finally
        {
            ctx.Response.OutputStream.Close();
        }
    }
}

// ===========================================================================
// ComputeWorker — background loop that performs fake periodic computation.
// This generates CPU-bound activity that the Datadog tracer can instrument.
// ===========================================================================
public sealed class ComputeWorker : BackgroundService
{
    private readonly ILogger<ComputeWorker> _logger;
    private static readonly Random Rng = new();

    public ComputeWorker(ILogger<ComputeWorker> logger) => _logger = logger;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("ComputeWorker started");

        while (!stoppingToken.IsCancellationRequested)
        {
            // Generate a random-sized workload and sum it
            int count  = Rng.Next(1_000, 50_000);
            long total = 0;
            for (int i = 1; i <= count; i++)
                total += i;

            _logger.LogDebug("ComputeWorker: sum(1..{Count}) = {Total}", count, total);

            // Wait between iterations — 15 seconds is long enough to see
            // periodic activity without overwhelming the log.
            await Task.Delay(TimeSpan.FromSeconds(15), stoppingToken);
        }

        _logger.LogInformation("ComputeWorker stopped");
    }
}
