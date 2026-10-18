/**
 * HTTP Bridge Server
 *
 * Runs a lightweight HTTP server on localhost that the Roblox Studio plugin
 * polls for commands. The MCP server pushes commands into a queue; the plugin
 * picks them up via GET /poll and posts results back via POST /result.
 */

import http from "node:http";
import { randomUUID } from "node:crypto";

export interface BridgeCommand {
  id: string;
  action: string;
  params: Record<string, unknown>;
}

interface PendingCommand {
  command: BridgeCommand;
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

export class StudioBridge {
  private server: http.Server | null = null;
  private port: number;
  private commandQueue: BridgeCommand[] = [];
  private pendingResults = new Map<string, PendingCommand>();
  private defaultTimeout: number;

  // Connection tracking
  private _lastPoll = 0;
  private _wasConnected = false;
  private _connectionCheckInterval: ReturnType<typeof setInterval> | null =
    null;
  private _commandCount = 0;

  constructor(port = 28821, defaultTimeout = 30000) {
    this.port = port;
    this.defaultTimeout = defaultTimeout;
  }

  /**
   * Start the HTTP bridge server.
   */
  async start(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.server = http.createServer((req, res) => {
        this.handleRequest(req, res);
      });

      this.server.on("error", (err) => {
        if ((err as NodeJS.ErrnoException).code === "EADDRINUSE") {
          reject(
            new Error(
              `Port ${this.port} is already in use. Another MCP bridge instance may be running.`
            )
          );
        } else {
          reject(err);
        }
      });

      this.server.listen(this.port, "127.0.0.1", () => {
        this.startConnectionMonitor();
        resolve();
      });
    });
  }

  /**
   * Stop the bridge server.
   */
  async stop(): Promise<void> {
    if (this._connectionCheckInterval) {
      clearInterval(this._connectionCheckInterval);
      this._connectionCheckInterval = null;
    }

    // Reject all pending commands
    for (const [id, pending] of this.pendingResults) {
      clearTimeout(pending.timer);
      pending.reject(new Error("Bridge shutting down"));
      this.pendingResults.delete(id);
    }

    return new Promise((resolve) => {
      if (this.server) {
        this.server.close(() => resolve());
      } else {
        resolve();
      }
    });
  }

  /**
   * Send a command to the Studio plugin and wait for the result.
   */
  async sendCommand(
    action: string,
    params: Record<string, unknown> = {},
    timeout?: number
  ): Promise<unknown> {
    const id = randomUUID();
    const command: BridgeCommand = { id, action, params };

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingResults.delete(id);
        reject(
          new Error(
            `Command "${action}" timed out after ${timeout ?? this.defaultTimeout}ms. ` +
              `Is the Roblox Studio plugin running and connected?`
          )
        );
      }, timeout ?? this.defaultTimeout);

      this.pendingResults.set(id, { command, resolve, reject, timer });
      this.commandQueue.push(command);
    });
  }

  /**
   * Check if the plugin is connected (has polled recently).
   */
  get isConnected(): boolean {
    return this._lastPoll > 0 && Date.now() - this._lastPoll < 5000;
  }

  /**
   * Periodically check if the plugin has gone away and log transitions.
   */
  private startConnectionMonitor(): void {
    this._connectionCheckInterval = setInterval(() => {
      const connected = this.isConnected;
      if (this._wasConnected && !connected) {
        this._wasConnected = false;
        this.log(
          "Studio plugin disconnected (no poll in 5s). Waiting for reconnect..."
        );
      }
    }, 2000);
  }

  private log(message: string): void {
    const ts = new Date().toLocaleTimeString();
    process.stderr.write(`[roblox-studio-mcp ${ts}] ${message}\n`);
  }

  private handleRequest(req: http.IncomingMessage, res: http.ServerResponse) {
    // CORS headers for any origin (local only)
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type");

    if (req.method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    const url = req.url ?? "/";

    if (req.method === "GET" && url === "/poll") {
      this.handlePoll(req, res);
    } else if (req.method === "POST" && url === "/result") {
      this.handleResult(req, res);
    } else if (req.method === "GET" && url === "/status") {
      this.handleStatus(req, res);
    } else {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Not found" }));
    }
  }

  private handlePoll(
    _req: http.IncomingMessage,
    res: http.ServerResponse
  ) {
    const wasConnected = this._wasConnected;
    this._lastPoll = Date.now();
    this._wasConnected = true;

    if (!wasConnected) {
      this.log("Studio plugin connected");
    }

    if (this.commandQueue.length === 0) {
      res.writeHead(204);
      res.end();
      return;
    }

    const command = this.commandQueue.shift()!;
    this._commandCount++;
    this.log(
      `-> ${command.action} (command #${this._commandCount}, id=${command.id.slice(0, 8)})`
    );
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(command));
  }

  private handleResult(req: http.IncomingMessage, res: http.ServerResponse) {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk.toString();
    });
    req.on("end", () => {
      try {
        const data = JSON.parse(body) as {
          id: string;
          result: Record<string, unknown>;
        };
        const pending = this.pendingResults.get(data.id);

        if (pending) {
          clearTimeout(pending.timer);
          this.pendingResults.delete(data.id);

          const actionName = pending.command.action;
          const success =
            data.result &&
            typeof data.result === "object" &&
            data.result.success !== false;
          if (success) {
            this.log(`<- ${actionName} completed (id=${data.id.slice(0, 8)})`);
          } else {
            const errMsg =
              (data.result as Record<string, unknown>)?.error ?? "unknown error";
            this.log(
              `<- ${actionName} FAILED: ${errMsg} (id=${data.id.slice(0, 8)})`
            );
          }

          pending.resolve(data.result);
        }

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      } catch {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Invalid JSON" }));
      }
    });
  }

  private handleStatus(
    _req: http.IncomingMessage,
    res: http.ServerResponse
  ) {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        connected: this.isConnected,
        lastPoll: this._lastPoll,
        lastPollAgo: this._lastPoll
          ? `${((Date.now() - this._lastPoll) / 1000).toFixed(1)}s`
          : "never",
        commandsProcessed: this._commandCount,
        pendingCommands: this.commandQueue.length,
        awaitingResults: this.pendingResults.size,
      })
    );
  }
}
