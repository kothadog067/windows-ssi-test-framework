using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using System.Net.Http;
using System.Text;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls("http://0.0.0.0:8080");
builder.Services.AddHttpClient();
builder.Services.AddCors(o => o.AddDefaultPolicy(p => p.AllowAnyOrigin().AllowAnyMethod().AllowAnyHeader()));

var app = builder.Build();
app.UseCors();

Console.WriteLine("===========================================");
Console.WriteLine("  .NET Dino Game Server started");
Console.WriteLine("  Port: 8080");
Console.WriteLine("  Endpoints:");
Console.WriteLine("    GET  /        - Serve game");
Console.WriteLine("    GET  /health  - Health check");
Console.WriteLine("===========================================");
Console.WriteLine("Waiting for Datadog SSI injection...");

// Health check
app.MapGet("/health", () => Results.Json(new { status = "ok", service = "dotnet-game-server" }));

// Serve the game HTML
app.MapGet("/", async (HttpContext ctx) =>
{
    ctx.Response.ContentType = "text/html; charset=utf-8";
    await ctx.Response.SendFileAsync("wwwroot/index.html");
});

// Serve static files
app.UseStaticFiles();

app.Run();
