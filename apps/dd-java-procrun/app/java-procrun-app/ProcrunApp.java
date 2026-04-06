import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;
import java.util.logging.Logger;

/**
 * ProcrunApp — lightweight HTTP server designed to run as a native Windows
 * Service managed by Apache Commons Daemon (Procrun).
 *
 * Procrun lifecycle hooks:
 *   start(String[]) — called by prunsrv.exe to start the service
 *   stop(String[])  — called by prunsrv.exe to stop the service
 *
 * Endpoints:
 *   GET /health  → {"status":"ok","service":"java-procrun-app"}
 *   GET /ping    → {"pong":true}
 *
 * Port: 8083
 */
public class ProcrunApp {

    private static final int PORT = 8083;
    private static final Logger LOG = Logger.getLogger(ProcrunApp.class.getName());

    private static HttpServer server;
    private static volatile boolean running = false;

    // ------------------------------------------------------------------
    // Procrun lifecycle entry points
    // ------------------------------------------------------------------

    /**
     * Called by prunsrv.exe (StartMode=Java, StartClass=ProcrunApp, StartMethod=start).
     * Must return promptly; the actual server runs in a daemon thread.
     */
    public static void start(String[] args) {
        LOG.info("ProcrunApp.start() invoked");
        try {
            server = HttpServer.create(new InetSocketAddress(PORT), /* backlog */ 50);
            server.setExecutor(Executors.newFixedThreadPool(4));
            server.createContext("/health", new HealthHandler());
            server.createContext("/ping",   new PingHandler());
            server.start();
            running = true;
            LOG.info("HTTP server listening on port " + PORT);
        } catch (IOException e) {
            LOG.severe("Failed to start HTTP server: " + e.getMessage());
            throw new RuntimeException(e);
        }
    }

    /**
     * Called by prunsrv.exe (StopMethod=stop).
     * Must stop the server and return promptly.
     */
    public static void stop(String[] args) {
        LOG.info("ProcrunApp.stop() invoked");
        running = false;
        if (server != null) {
            server.stop(3);   // 3-second graceful delay
            LOG.info("HTTP server stopped");
        }
    }

    /**
     * Standard main() — used when running outside of Procrun (e.g. local dev).
     */
    public static void main(String[] args) throws InterruptedException {
        start(args);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> stop(new String[0])));
        // Block the main thread so the JVM stays alive.
        while (running) {
            Thread.sleep(1000);
        }
    }

    // ------------------------------------------------------------------
    // HTTP Handlers
    // ------------------------------------------------------------------

    static class HealthHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"GET".equalsIgnoreCase(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\":\"method not allowed\"}");
                return;
            }
            sendResponse(exchange, 200, "{\"status\":\"ok\",\"service\":\"java-procrun-app\"}");
        }
    }

    static class PingHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"GET".equalsIgnoreCase(exchange.getRequestMethod())) {
                sendResponse(exchange, 405, "{\"error\":\"method not allowed\"}");
                return;
            }
            sendResponse(exchange, 200, "{\"pong\":true}");
        }
    }

    // ------------------------------------------------------------------
    // Utility
    // ------------------------------------------------------------------

    private static void sendResponse(HttpExchange exchange, int statusCode, String body)
            throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=UTF-8");
        exchange.sendResponseHeaders(statusCode, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }
}
