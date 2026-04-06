using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls("http://0.0.0.0:8086");

var app = builder.Build();

app.MapGet("/health", () => Results.Json(new {
    status = "ok",
    service = "dotnet-selfcontained-app",
    version = "1.0",
    mode = "self-contained-single-file"
}));

app.MapGet("/info", () => Results.Json(new {
    runtime = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
    pid = System.Diagnostics.Process.GetCurrentProcess().Id,
    processName = System.Diagnostics.Process.GetCurrentProcess().ProcessName
}));

app.Run();
