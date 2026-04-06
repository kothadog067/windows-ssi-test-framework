using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);

// Listen on both port 80 (IIS default) and 8082 (direct Kestrel fallback)
builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(80);
    options.ListenAnyIP(8082);
});

var app = builder.Build();

app.MapGet("/health", () =>
    Results.Json(new { status = "ok", service = "dotnet-iis-app" }));

app.MapGet("/echo", (string? msg) =>
    Results.Json(new { echo = msg ?? "" }));

app.MapPost("/compute", async (HttpContext context) =>
{
    // Read optional JSON body with a list of numbers
    int[] numbers = Array.Empty<int>();
    try
    {
        var body = await JsonSerializer.DeserializeAsync<ComputeRequest>(context.Request.Body);
        if (body?.Values != null)
            numbers = body.Values;
    }
    catch
    {
        // Ignore parse errors; fall back to default
    }

    // Fake work: sum the provided numbers, or use a default range
    if (numbers.Length == 0)
        numbers = Enumerable.Range(1, 100).ToArray();

    long sum = 0;
    foreach (var n in numbers)
        sum += n;

    // Simulate a small amount of CPU work
    await Task.Delay(5);

    return Results.Json(new { result = sum });
});

app.Run();

record ComputeRequest(int[]? Values);
