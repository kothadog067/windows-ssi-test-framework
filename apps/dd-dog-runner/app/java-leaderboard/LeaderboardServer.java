import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;

import java.io.*;
import java.net.InetSocketAddress;
import java.util.*;
import java.util.concurrent.*;
import java.util.stream.Collectors;

/**
 * Java Leaderboard Service
 * Demo service for Windows Host-Wide SSI testing
 * Runs on port 8081
 */
public class LeaderboardServer {

    // In-memory leaderboard storage
    private static final List<ScoreEntry> scores = new CopyOnWriteArrayList<>();
    private static final int MAX_SCORES = 10;

    public static void main(String[] args) throws Exception {
        int port = 8081;
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);

        server.createContext("/leaderboard", new LeaderboardHandler());
        server.createContext("/score", new ScoreSubmitHandler());
        server.createContext("/health", new HealthHandler());

        server.setExecutor(Executors.newFixedThreadPool(4));
        server.start();

        System.out.println("===========================================");
        System.out.println("  Java Leaderboard Service started");
        System.out.println("  Port: " + port);
        System.out.println("  Endpoints:");
        System.out.println("    GET  /leaderboard  - Get top scores");
        System.out.println("    POST /score        - Submit a score");
        System.out.println("    GET  /health       - Health check");
        System.out.println("===========================================");
        System.out.println("Waiting for Datadog SSI injection...");

        // Keep alive
        Thread.currentThread().join();
    }

    // --- Handlers ---

    static class LeaderboardHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            addCorsHeaders(exchange);
            if ("OPTIONS".equals(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(204, -1);
                return;
            }

            List<ScoreEntry> top = scores.stream()
                .sorted(Comparator.comparingInt(ScoreEntry::getScore).reversed())
                .limit(MAX_SCORES)
                .collect(Collectors.toList());

            StringBuilder json = new StringBuilder("[");
            for (int i = 0; i < top.size(); i++) {
                ScoreEntry e = top.get(i);
                if (i > 0) json.append(",");
                json.append(String.format(
                    "{\"rank\":%d,\"name\":\"%s\",\"score\":%d,\"date\":\"%s\"}",
                    i + 1, escapeJson(e.getName()), e.getScore(), e.getDate()
                ));
            }
            json.append("]");

            sendJson(exchange, 200, json.toString());
        }
    }

    static class ScoreSubmitHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            addCorsHeaders(exchange);
            if ("OPTIONS".equals(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(204, -1);
                return;
            }
            if (!"POST".equals(exchange.getRequestMethod())) {
                sendJson(exchange, 405, "{\"error\":\"Method not allowed\"}");
                return;
            }

            String body = new String(exchange.getRequestBody().readAllBytes());
            String name = extractJsonField(body, "name");
            String scoreStr = extractJsonField(body, "score");

            if (name == null || scoreStr == null) {
                sendJson(exchange, 400, "{\"error\":\"Missing name or score\"}");
                return;
            }

            int score;
            try {
                score = Integer.parseInt(scoreStr);
            } catch (NumberFormatException e) {
                sendJson(exchange, 400, "{\"error\":\"Invalid score\"}");
                return;
            }

            ScoreEntry entry = new ScoreEntry(name, score);
            scores.add(entry);

            // Trim to top 100 to avoid unbounded growth
            if (scores.size() > 100) {
                scores.sort(Comparator.comparingInt(ScoreEntry::getScore).reversed());
                while (scores.size() > 100) scores.remove(scores.size() - 1);
            }

            System.out.println("[Score] " + name + " scored " + score);
            sendJson(exchange, 201, "{\"status\":\"saved\",\"name\":\"" + escapeJson(name) + "\",\"score\":" + score + "}");
        }
    }

    static class HealthHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            addCorsHeaders(exchange);
            sendJson(exchange, 200, "{\"status\":\"ok\",\"service\":\"java-leaderboard\",\"scores\":" + scores.size() + "}");
        }
    }

    // --- Helpers ---

    static void sendJson(HttpExchange exchange, int code, String body) throws IOException {
        byte[] bytes = body.getBytes("UTF-8");
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=UTF-8");
        exchange.sendResponseHeaders(code, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    static void addCorsHeaders(HttpExchange exchange) {
        exchange.getResponseHeaders().set("Access-Control-Allow-Origin", "*");
        exchange.getResponseHeaders().set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
        exchange.getResponseHeaders().set("Access-Control-Allow-Headers", "Content-Type");
    }

    static String extractJsonField(String json, String field) {
        String key = "\"" + field + "\"";
        int idx = json.indexOf(key);
        if (idx < 0) return null;
        int colon = json.indexOf(":", idx);
        if (colon < 0) return null;
        int start = colon + 1;
        while (start < json.length() && Character.isWhitespace(json.charAt(start))) start++;
        if (start >= json.length()) return null;
        if (json.charAt(start) == '"') {
            int end = json.indexOf('"', start + 1);
            if (end < 0) return null;
            return json.substring(start + 1, end);
        } else {
            int end = start;
            while (end < json.length() && json.charAt(end) != ',' && json.charAt(end) != '}') end++;
            return json.substring(start, end).trim();
        }
    }

    static String escapeJson(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    // --- Data Model ---

    static class ScoreEntry {
        private final String name;
        private final int score;
        private final String date;

        ScoreEntry(String name, int score) {
            this.name = name;
            this.score = score;
            this.date = new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm").format(new Date());
        }

        String getName() { return name; }
        int getScore() { return score; }
        String getDate() { return date; }
    }
}
