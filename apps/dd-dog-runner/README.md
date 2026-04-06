# dd-dog-runner

A Dino-style runner game that runs as two real Windows Services, used to test Datadog Windows Host-Wide SSI on both **.NET** and **Java** simultaneously.

## Services

| Service | Runtime | Port | DD_SERVICE |
|---------|---------|------|------------|
| DDGameServer | .NET 8 (NSSM) | 8080 | `dd-game-server` |
| DDLeaderboard | Java 21 (NSSM) | 8081 | `dd-leaderboard` |

## Quick Start

```powershell
# Full setup with Datadog Agent + SSI
.\scripts\setup.ps1 -DDApiKey "your_key" -InstallAgent

# Verify
.\scripts\verify.ps1 -TargetHost localhost

# Teardown
.\scripts\teardown.ps1
```

## Endpoints

- `GET  /`            — game UI
- `GET  /health`      — `{"status":"ok","service":"dotnet-game-server"}`
- `GET  /leaderboard` — top 10 scores
- `POST /score`       — `{"name":"player","score":42}`
- `GET  /health`      — `{"status":"ok","service":"java-leaderboard"}`
