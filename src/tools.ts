/**
 * MCP Tool Definitions for Roblox Studio
 *
 * 6 consolidated tools with action-based routing:
 *   roblox_get      – read-only queries (workspace tree, instances, properties, search, logs, etc.)
 *   roblox_manage   – mutations (create, update, delete, clone, reparent, undo/redo, selection)
 *   roblox_script   – script CRUD and execution
 *   roblox_scene    – camera control and viewport screenshot
 *   roblox_toolbox  – search Creator Store, insert models, strip scripts
 *   roblox_playtest – start/stop/status, interact with running game
 */

import type { StudioBridge } from "./bridge.js";
import { renderScene, type SceneData } from "./renderer.js";

// ------------------------------------------------------------------
// Types
// ------------------------------------------------------------------

export interface ToolDefinition {
  name: string;
  description: string;
  inputSchema: {
    type: "object";
    properties: Record<string, unknown>;
    required?: string[];
  };
}

export interface ToolResult {
  [key: string]: unknown;
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
}

type ToolHandler = (
  args: Record<string, unknown>,
  bridge: StudioBridge
) => Promise<ToolResult>;

// ------------------------------------------------------------------
// Registry
// ------------------------------------------------------------------

const toolDefinitions: ToolDefinition[] = [];
const toolHandlers = new Map<string, ToolHandler>();

function defineTool(def: ToolDefinition, handler: ToolHandler): void {
  toolDefinitions.push(def);
  toolHandlers.set(def.name, handler);
}

export function getToolDefinitions(): ToolDefinition[] {
  return toolDefinitions;
}

export function getToolHandler(name: string): ToolHandler | undefined {
  return toolHandlers.get(name);
}

// ------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------

function formatResult(result: unknown): ToolResult {
  const data = result as Record<string, unknown>;
  if (data && typeof data === "object" && data.success === false) {
    return {
      content: [
        {
          type: "text",
          text: `Error: ${data.error ?? "Unknown error"}\n\n${JSON.stringify(data, null, 2)}`,
        },
      ],
      isError: true,
    };
  }
  return {
    content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
  };
}

async function bridgeCall(
  bridge: StudioBridge,
  action: string,
  params: Record<string, unknown> = {},
  timeout?: number
): Promise<ToolResult> {
  if (!bridge.isConnected) {
    return {
      content: [
        {
          type: "text",
          text: "Roblox Studio plugin is not connected. Make sure:\n1. Roblox Studio is open\n2. The MCP Bridge plugin is installed (see install-plugin)\n3. The MCP Bridge button in the Studio toolbar is active (clicked on)",
        },
      ],
      isError: true,
    };
  }
  const result = await bridge.sendCommand(action, params, timeout);
  return formatResult(result);
}

// ==================================================================
// TOOL DEFINITIONS (6 consolidated tools)
// ==================================================================

// ------------------------------------------------------------------
// 1. roblox_get — Read-only queries
// ------------------------------------------------------------------

defineTool(
  {
    name: "roblox_get",
    description: `Read-only queries against the Roblox Studio scene. Use the "action" parameter to select what to retrieve.

Actions:
- "ping": Check plugin connection status and get place info.
- "tree": Get ASCII hierarchy tree. Params: root (path, default game), maxDepth (number).
- "search": Find instances by name/class. Params: query (substring), className, root, maxResults.
- "instance": Get detailed info about one instance. Params: path (required), depth (children levels, default 1).
- "properties": Get all readable properties. Params: path (required), properties (array of extra names).
- "descendants_summary": Class-count breakdown under a root. Params: root (default Workspace).
- "selection": Get the currently selected instances. Params: depth.
- "output_log": Read recent Output log entries. Params: maxEntries (default 50).
- "texture_info": Get texture and decal asset IDs for an instance and its descendants. Returns MeshPart TextureIDs, Decal/Texture asset IDs, and materials. Useful for understanding visual appearance without rendering textures in screenshots. Params: path (required), maxDepth (default 2).`,
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["ping", "tree", "search", "instance", "properties", "descendants_summary", "selection", "output_log", "texture_info"],
          description: "Which query to perform",
        },
        // Shared params — each action uses the relevant subset
        path: { type: "string", description: "Instance path (dot-separated)" },
        root: { type: "string", description: "Root path to scope the query" },
        query: { type: "string", description: "Search substring (for search action)" },
        className: { type: "string", description: "Filter by class name (for search)" },
        maxDepth: { type: "number", description: "Tree depth limit" },
        maxResults: { type: "number", description: "Result limit for search" },
        maxEntries: { type: "number", description: "Log entry limit for output_log" },
        depth: { type: "number", description: "Children depth for instance/selection" },
        properties: {
          type: "array",
          items: { type: "string" },
          description: "Extra property names to read (for properties action)",
        },
      },
      required: ["action"],
    },
  },
  async (args, bridge) => {
    const action = args.action as string;
    const map: Record<string, { cmd: string; params: Record<string, unknown> }> = {
      ping: { cmd: "ping", params: {} },
      tree: { cmd: "get-workspace-tree", params: { root: args.root, maxDepth: args.maxDepth } },
      search: { cmd: "search-instances", params: { query: args.query, className: args.className, root: args.root, maxResults: args.maxResults } },
      instance: { cmd: "get-instance", params: { path: args.path, depth: args.depth } },
      properties: { cmd: "get-properties", params: { path: args.path, properties: args.properties } },
      descendants_summary: { cmd: "get-descendants-summary", params: { root: args.root } },
      selection: { cmd: "get-selection", params: { depth: args.depth } },
      output_log: { cmd: "get-output-log", params: { maxEntries: args.maxEntries } },
      texture_info: { cmd: "get-texture-info", params: { path: args.path, maxDepth: args.maxDepth } },
    };
    const entry = map[action];
    if (!entry) {
      return { content: [{ type: "text", text: `Unknown action "${action}"` }], isError: true };
    }
    return bridgeCall(bridge, entry.cmd, entry.params);
  }
);

// ------------------------------------------------------------------
// 2. roblox_manage — Mutations
// ------------------------------------------------------------------

defineTool(
  {
    name: "roblox_manage",
    description: `Mutate instances in the Roblox Studio scene.

Actions:
- "create": Create a new instance. Params: className (required), name, parent (path), properties (object).
- "create_multiple": Batch-create instances. Params: parent (default path), instances (array of {className, name, parent?, properties?}).
- "update": Update properties on an existing instance. Params: path (required), name, properties (object).
- "reset_pivot": Reset a Model's WorldPivot to its bounding box center, or a BasePart's PivotOffset to zero. Params: path (required). Use this when positioning/PivotTo is behaving unexpectedly — a stale WorldPivot far from the geometry is a common cause. Automatically done on toolbox insert, but useful for debugging.
- "delete": Destroy an instance. Params: path (required).
- "clone": Clone an instance tree. Params: path (required), name, parent.
- "reparent": Move an instance to a new parent. Params: path (required), newParent (required).
- "set_selection": Set the Studio selection. Params: paths (array of paths).
- "undo": Undo last action.
- "redo": Redo last undone action.

Property format: vectors as {X,Y,Z}, colors as {R,G,B} (0-1 range), booleans, strings, numbers. Example: {"Position": {"X":0,"Y":5,"Z":0}, "Size": {"X":4,"Y":1,"Z":4}, "Anchored": true, "Material": "Neon", "Color": {"R":1,"G":0,"B":0}}`,
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["create", "create_multiple", "update", "reset_pivot", "delete", "clone", "reparent", "set_selection", "undo", "redo"],
          description: "Which mutation to perform",
        },
        className: { type: "string", description: 'Class to create (e.g. "Part", "Model", "Folder", "SpawnLocation")' },
        path: { type: "string", description: "Target instance path" },
        name: { type: "string", description: "Instance name" },
        parent: { type: "string", description: "Parent path (default Workspace)" },
        newParent: { type: "string", description: "New parent path (for reparent)" },
        properties: { type: "object", description: "Properties to set/update" },

        instances: {
          type: "array",
          description: "Array of {className, name, parent?, properties?} for create_multiple",
          items: {
            type: "object",
            properties: {
              className: { type: "string" },
              name: { type: "string" },
              parent: { type: "string" },
              properties: { type: "object" },
            },
            required: ["className"],
          },
        },
        paths: {
          type: "array",
          items: { type: "string" },
          description: "Instance paths (for set_selection)",
        },
      },
      required: ["action"],
    },
  },
  async (args, bridge) => {
    const action = args.action as string;
    const map: Record<string, { cmd: string; params: Record<string, unknown> }> = {
      create: { cmd: "create-instance", params: { className: args.className, name: args.name, parent: args.parent, properties: args.properties } },
      create_multiple: { cmd: "create-multiple", params: { parent: args.parent, instances: args.instances } },
      update: { cmd: "update-instance", params: { path: args.path, name: args.name, properties: args.properties } },
      reset_pivot: { cmd: "reset-pivot", params: { path: args.path } },
      delete: { cmd: "delete-instance", params: { path: args.path } },
      clone: { cmd: "clone-instance", params: { path: args.path, name: args.name, parent: args.parent } },
      reparent: { cmd: "reparent-instance", params: { path: args.path, newParent: args.newParent } },
      set_selection: { cmd: "set-selection", params: { paths: args.paths } },
      undo: { cmd: "undo", params: {} },
      redo: { cmd: "redo", params: {} },
    };
    const entry = map[action];
    if (!entry) {
      return { content: [{ type: "text", text: `Unknown action "${action}"` }], isError: true };
    }
    return bridgeCall(bridge, entry.cmd, entry.params);
  }
);

// ------------------------------------------------------------------
// 3. roblox_script — Script CRUD & execution
// ------------------------------------------------------------------

defineTool(
  {
    name: "roblox_script",
    description: `Create, read, update, and execute Lua scripts in Roblox Studio.

Actions:
- "create": Create a new script. Params: source (required), scriptType ("Script"|"LocalScript"|"ModuleScript"), name, parent, disabled.
- "read": Read a script's source. Params: path (required).
- "update": Update a script's source code. Params: path (required), source (required).
- "execute": Run a Lua snippet in Studio (server context). Returns the result or error. Params: source (required). Code runs in a function body — use 'return' to get values back.

Common parent locations: "ServerScriptService" (server scripts), "StarterPlayerScripts" (local scripts), "ReplicatedStorage" (modules).`,
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["create", "read", "update", "execute"],
          description: "Which script operation to perform",
        },
        path: { type: "string", description: "Path to existing script" },
        source: { type: "string", description: "Lua source code" },
        scriptType: {
          type: "string",
          enum: ["Script", "LocalScript", "ModuleScript"],
          description: "Type of script to create (default Script)",
        },
        name: { type: "string", description: "Script name" },
        parent: { type: "string", description: "Parent path" },
        disabled: { type: "boolean", description: "Create in disabled state" },
      },
      required: ["action"],
    },
  },
  async (args, bridge) => {
    const action = args.action as string;
    const map: Record<string, { cmd: string; params: Record<string, unknown>; timeout?: number }> = {
      create: {
        cmd: "create-script",
        params: { source: args.source, scriptType: args.scriptType, name: args.name, parent: args.parent, disabled: args.disabled },
      },
      read: { cmd: "get-script-source", params: { path: args.path } },
      update: { cmd: "update-script-source", params: { path: args.path, source: args.source } },
      execute: { cmd: "execute-script", params: { source: args.source }, timeout: 60000 },
    };
    const entry = map[action];
    if (!entry) {
      return { content: [{ type: "text", text: `Unknown action "${action}"` }], isError: true };
    }
    return bridgeCall(bridge, entry.cmd, entry.params, entry.timeout);
  }
);

// ------------------------------------------------------------------
// 4. roblox_scene — Camera & viewport screenshot
// ------------------------------------------------------------------

defineTool(
  {
    name: "roblox_scene",
    description: `Control the camera and capture rendered viewport screenshots.

Actions:
- "screenshot": Render a PNG image of what the camera currently sees. Returns an image you can analyze visually. Use it to verify placement, scale, orientation, and scene composition. No textures are rendered — use roblox_get action "texture_info" if you need texture/decal context. Params: maxParts (default 2000).
- "move_camera": Reposition the Studio camera. Two modes:
  (A) Auto-frame an object: set focusInstance to an instance path (e.g. "Workspace.GasStation"). The camera automatically positions itself at a good distance and angle to see the entire object. Optional: angle (elevation in degrees, default 35), yaw (horizontal rotation in degrees, default 45).
  (B) Explicit placement: set position {X,Y,Z} (where the camera IS in world space) and lookAt {X,Y,Z} (the world point the camera POINTS AT). Both must be provided and must be different points. Example: position {X:50, Y:20, Z:50} lookAt {X:0, Y:0, Z:0} places camera at (50,20,50) aiming at the origin.

Typical workflow: move_camera (frame your subject) → screenshot (see the result) → evaluate → adjust.`,
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["screenshot", "move_camera"],
          description: "Which scene operation",
        },
        maxParts: { type: "number", description: "Max parts to render (default 2000, for screenshot)" },
        focusInstance: {
          type: "string",
          description: 'For move_camera mode A: instance path to auto-frame, e.g. "Workspace.MyModel". Camera positions itself to see the whole object.',
        },
        angle: {
          type: "number",
          description: "For move_camera with focusInstance: camera elevation angle in degrees (default 35). 0 = eye level, 90 = top-down.",
        },
        yaw: {
          type: "number",
          description: "For move_camera with focusInstance: horizontal orbit angle in degrees (default 45). 0 = front, 90 = side, 180 = back.",
        },
        position: {
          type: "object",
          description: "For move_camera mode B: where the camera IS in world space {X,Y,Z}. Must also provide lookAt.",
          properties: { X: { type: "number" }, Y: { type: "number" }, Z: { type: "number" } },
        },
        lookAt: {
          type: "object",
          description: "For move_camera mode B: the world point the camera AIMS AT {X,Y,Z}. Must differ from position.",
          properties: { X: { type: "number" }, Y: { type: "number" }, Z: { type: "number" } },
        },
      },
      required: ["action"],
    },
  },
  async (args, bridge) => {
    const action = args.action as string;

    if (action === "move_camera") {
      return bridgeCall(bridge, "move-camera", {
        position: args.position,
        lookAt: args.lookAt,
        focusInstance: args.focusInstance,
        angle: args.angle,
        yaw: args.yaw,
      });
    }

    if (action === "screenshot") {
      if (!bridge.isConnected) {
        return {
          content: [{ type: "text", text: "Roblox Studio plugin is not connected." }],
          isError: true,
        };
      }

      const result = (await bridge.sendCommand(
        "capture-viewport",
        { maxParts: args.maxParts ?? 2000 },
        15000
      )) as Record<string, unknown>;

      if (!result || result.success === false) {
        return {
          content: [{ type: "text", text: `Error capturing viewport: ${result?.error ?? "Unknown error"}` }],
          isError: true,
        };
      }

      const scene = result as unknown as SceneData & { success: boolean };

      if (!scene.parts || scene.parts.length === 0) {
        return {
          content: [{ type: "text", text: "Scene is empty — no visible parts found in workspace." }],
        };
      }

      try {
        const rendered = await renderScene(scene);
        return {
          content: [
            {
              type: "image" as const,
              data: rendered.pngBase64,
              mimeType: "image/png",
            } as unknown as { type: "text"; text: string },
            {
              type: "text",
              text: `Viewport capture: ${rendered.partCount} parts, ${rendered.faceCount} visible faces, ${rendered.width}x${rendered.height}px.${scene.truncated ? " (Truncated — more parts exist.)" : ""}`,
            },
          ],
        };
      } catch (err) {
        return {
          content: [{ type: "text", text: `Render error: ${err instanceof Error ? err.message : String(err)}` }],
          isError: true,
        };
      }
    }

    return { content: [{ type: "text", text: `Unknown action "${action}"` }], isError: true };
  }
);

// ------------------------------------------------------------------
// 5. roblox_toolbox — Search, insert, sanitize
// ------------------------------------------------------------------

defineTool(
  {
    name: "roblox_toolbox",
    description: `Search the Roblox Creator Store, insert models, and sanitize them.

Actions:
- "search": Search for free models/decals/audio. Returns AssetId, Name, Creator, HasScripts, IsEndorsed. Params: query (required), category ("FreeModels"|"FreeDecals"|"FreeAudio"), maxResults (default 20). Prefer assets where HasScripts=false or IsEndorsed=true.
- "insert": Insert an asset by ID. Params: assetId (required), parent (path), position {X,Y,Z}. CRITICAL: Toolbox models often contain far more than their name implies — a "gas station" may bundle pumps, signs, shelving, vehicles, lighting as descendants. Always inspect the returned hierarchy before building additional objects. Check orientation (model axes may not match your scene) and scale (toolbox models vary wildly in size, Roblox studs ≈ 0.28m).
- "strip_scripts": Remove all scripts from an instance tree. Params: path (required), scriptTypes (array, default all). Always do this after inserting models with HasScripts=true.`,
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["search", "insert", "strip_scripts"],
          description: "Which toolbox operation",
        },
        query: { type: "string", description: "Search query (for search)" },
        category: {
          type: "string",
          enum: ["FreeModels", "FreeDecals", "FreeAudio"],
          description: "Asset category (for search, default FreeModels)",
        },
        maxResults: { type: "number", description: "Max results (for search, default 20)" },
        assetId: { type: "number", description: "Asset ID to insert (for insert)" },
        parent: { type: "string", description: "Parent path (for insert, default Workspace)" },
        position: {
          type: "object",
          description: "Position {X,Y,Z} (for insert)",
          properties: { X: { type: "number" }, Y: { type: "number" }, Z: { type: "number" } },
        },
        path: { type: "string", description: "Instance path (for strip_scripts)" },
        scriptTypes: {
          type: "array",
          items: { type: "string", enum: ["Script", "LocalScript", "ModuleScript"] },
          description: "Script types to remove (for strip_scripts, default all)",
        },
      },
      required: ["action"],
    },
  },
  async (args, bridge) => {
    const action = args.action as string;

    if (action === "search") {
      // Handled on Node.js side using the public Roblox Toolbox Service API
      const query = (args.query as string) || "";
      const category = (args.category as string) || "FreeModels";
      const maxResults = Math.min((args.maxResults as number) || 20, 50);

      const categoryMap: Record<string, number> = { FreeModels: 10, FreeDecals: 13, FreeAudio: 40 };
      const assetTypeId = categoryMap[category] ?? 10;

      try {
        const searchUrl = `https://apis.roblox.com/toolbox-service/v1/marketplace/${assetTypeId}?keyword=${encodeURIComponent(query)}&num=${maxResults}&supportedLocales=en_us`;
        const searchRes = await fetch(searchUrl);
        if (!searchRes.ok) {
          return { content: [{ type: "text", text: `Toolbox API error: ${searchRes.status} ${searchRes.statusText}` }], isError: true };
        }
        const searchData = (await searchRes.json()) as { totalResults: number; data: Array<{ id: number }> };

        if (!searchData.data || searchData.data.length === 0) {
          return { content: [{ type: "text", text: JSON.stringify({ success: true, results: [], count: 0, query }, null, 2) }] };
        }

        const assetIds = searchData.data.map((d) => d.id);
        const detailsUrl = `https://apis.roblox.com/toolbox-service/v1/items/details?assetIds=${assetIds.join(",")}`;
        const detailsRes = await fetch(detailsUrl);
        let results: Array<Record<string, unknown>>;

        if (detailsRes.ok) {
          const detailsData = (await detailsRes.json()) as {
            data: Array<{
              asset: { id: number; name: string; description: string; hasScripts: boolean; isEndorsed: boolean };
              creator: { name: string; isVerifiedCreator: boolean };
            }>;
          };
          results = detailsData.data.map((item) => ({
            AssetId: item.asset.id,
            Name: item.asset.name,
            Description: (item.asset.description ?? "").slice(0, 100),
            HasScripts: item.asset.hasScripts,
            IsEndorsed: item.asset.isEndorsed,
            Creator: item.creator.name,
            IsVerifiedCreator: item.creator.isVerifiedCreator,
          }));
        } else {
          results = assetIds.map((id) => ({ AssetId: id }));
        }

        return {
          content: [{ type: "text", text: JSON.stringify({ success: true, results, count: results.length, totalResults: searchData.totalResults, query }, null, 2) }],
        };
      } catch (err) {
        return { content: [{ type: "text", text: `Search failed: ${err instanceof Error ? err.message : String(err)}` }], isError: true };
      }
    }

    if (action === "insert") {
      return bridgeCall(bridge, "insert-model", { assetId: args.assetId, parent: args.parent, position: args.position }, 30000);
    }

    if (action === "strip_scripts") {
      return bridgeCall(bridge, "remove-scripts-from", { path: args.path, scriptTypes: args.scriptTypes });
    }

    return { content: [{ type: "text", text: `Unknown action "${action}"` }], isError: true };
  }
);

// ------------------------------------------------------------------
// 6. roblox_playtest — Test mode lifecycle & interaction
// ------------------------------------------------------------------

defineTool(
  {
    name: "roblox_playtest",
    description: `Control Roblox Studio playtest sessions and interact with the running game.

Actions:
- "start": Begin playtest (RunService:Run). Scripts execute, physics activate. Params: mode ("run"|"play", default "run").
- "stop": End playtest, return to Edit mode.
- "status": Get current mode (Edit/Running/Client/Server).
- "move_camera": Reposition camera during playtest. Params: position {X,Y,Z}, lookAt {X,Y,Z}.
- "fire_click": Trigger a ClickDetector. Params: path (instance path).
- "fire_proximity": Trigger a ProximityPrompt. Params: path (instance path).
- "get_state": Read game state (player count, leaderstats, runtime info).
- "execute": Run Lua code in the live game context. Params: code (string).

Workflow: start → interact/observe → screenshot (via roblox_scene) → evaluate → stop → fix → repeat.`,
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["start", "stop", "status", "move_camera", "fire_click", "fire_proximity", "get_state", "execute"],
          description: "Which playtest action",
        },
        mode: { type: "string", enum: ["run", "play"], description: 'For start: "run" (server only) or "play" (client+server)' },
        position: {
          type: "object",
          description: "Camera position {X,Y,Z} (for move_camera)",
          properties: { X: { type: "number" }, Y: { type: "number" }, Z: { type: "number" } },
        },
        lookAt: {
          type: "object",
          description: "Look-at target {X,Y,Z} (for move_camera)",
          properties: { X: { type: "number" }, Y: { type: "number" }, Z: { type: "number" } },
        },
        path: { type: "string", description: "Instance path (for fire_click/fire_proximity)" },
        code: { type: "string", description: "Lua code (for execute)" },
      },
      required: ["action"],
    },
  },
  async (args, bridge) => {
    const action = args.action as string;
    const map: Record<string, { cmd: string; params: Record<string, unknown> }> = {
      start: { cmd: "playtest-start", params: { mode: args.mode ?? "run" } },
      stop: { cmd: "playtest-stop", params: {} },
      status: { cmd: "playtest-status", params: {} },
      move_camera: { cmd: "playtest-action", params: { action: "move_camera", position: args.position, lookAt: args.lookAt } },
      fire_click: { cmd: "playtest-action", params: { action: "fire_click", path: args.path } },
      fire_proximity: { cmd: "playtest-action", params: { action: "fire_proximity", path: args.path } },
      get_state: { cmd: "playtest-action", params: { action: "get_state" } },
      execute: { cmd: "playtest-action", params: { action: "execute", code: args.code } },
    };
    const entry = map[action];
    if (!entry) {
      return { content: [{ type: "text", text: `Unknown action "${action}"` }], isError: true };
    }
    return bridgeCall(bridge, entry.cmd, entry.params, 30000);
  }
);
