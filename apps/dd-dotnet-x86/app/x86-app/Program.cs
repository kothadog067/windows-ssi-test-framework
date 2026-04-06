using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls("http://0.0.0.0:8091");

var app = builder.Build();

app.MapGet("/health", () => Results.Json(new {
    status = "ok",
    service = "dotnet-x86-app",
    version = "1.0",
    arch = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
    is32bit = !System.Environment.Is64BitProcess
}));

app.MapGet("/info", () => Results.Json(new {
    pid = System.Diagnostics.Process.GetCurrentProcess().Id,
    is64bit_process = System.Environment.Is64BitProcess,
    is64bit_os = System.Environment.Is64BitOperatingSystem,
    arch = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString()
}));

app.Run();
