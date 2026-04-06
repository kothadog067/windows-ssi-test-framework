using System;
using System.Net;
using System.Text;
using System.Threading;

class Program
{
    static readonly HttpListener _listener = new HttpListener();
    static volatile bool _running = true;

    static void Main(string[] args)
    {
        string port = "8087";
        _listener.Prefixes.Add($"http://+:{port}/");
        _listener.Start();
        Console.WriteLine($"[DotnetFramework] Listening on port {port}");

        AppDomain.CurrentDomain.ProcessExit += (s, e) => { _running = false; _listener.Stop(); };
        Console.CancelKeyPress += (s, e) => { e.Cancel = true; _running = false; _listener.Stop(); };

        while (_running)
        {
            HttpListenerContext ctx;
            try { ctx = _listener.GetContext(); }
            catch { break; }

            ThreadPool.QueueUserWorkItem(_ => HandleRequest(ctx));
        }
    }

    static void HandleRequest(HttpListenerContext ctx)
    {
        string path = ctx.Request.Url?.AbsolutePath ?? "/";
        byte[] body;
        string contentType = "application/json";

        if (path == "/health" || path == "/")
        {
            string json = "{\"status\":\"ok\",\"service\":\"dotnet-framework-app\",\"framework\":\"net48\",\"version\":\"1.0\"}";
            body = Encoding.UTF8.GetBytes(json);
        }
        else if (path == "/info")
        {
            string json = $"{{\"clr\":\"{Environment.Version}\",\"pid\":{System.Diagnostics.Process.GetCurrentProcess().Id}}}";
            body = Encoding.UTF8.GetBytes(json);
        }
        else
        {
            body = Encoding.UTF8.GetBytes("{\"error\":\"not found\"}");
            ctx.Response.StatusCode = 404;
        }

        ctx.Response.ContentType = contentType;
        ctx.Response.ContentLength64 = body.Length;
        ctx.Response.OutputStream.Write(body, 0, body.Length);
        ctx.Response.OutputStream.Close();
    }
}
