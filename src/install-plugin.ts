#!/usr/bin/env node

/**
 * Plugin Installer
 *
 * Copies the Roblox Studio plugin file to the local Roblox Studio plugins
 * directory so it loads automatically when Studio starts.
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

function getPluginsDir(): string {
  const platform = os.platform();
  const home = os.homedir();

  if (platform === "darwin") {
    // macOS
    return path.join(home, "Documents", "Roblox", "Plugins");
  } else if (platform === "win32") {
    // Windows - try AppData first, then Documents
    const appData = process.env.LOCALAPPDATA ?? path.join(home, "AppData", "Local");
    const robloxPlugins = path.join(appData, "Roblox", "Plugins");
    if (fs.existsSync(robloxPlugins)) {
      return robloxPlugins;
    }
    return path.join(home, "Documents", "Roblox", "Plugins");
  } else {
    // Linux (rare for Studio)
    return path.join(home, ".local", "share", "Roblox", "Plugins");
  }
}

function main() {
  const pluginsDir = getPluginsDir();
  const sourceFile = path.join(
    path.dirname(new URL(import.meta.url).pathname),
    "..",
    "plugin",
    "RobloxStudioMCP.server.lua"
  );
  const destFile = path.join(pluginsDir, "RobloxStudioMCP.server.lua");

  console.log("Roblox Studio MCP Plugin Installer");
  console.log("===================================\n");
  console.log(`Source: ${sourceFile}`);
  console.log(`Target: ${destFile}\n`);

  // Create plugins dir if it doesn't exist
  if (!fs.existsSync(pluginsDir)) {
    console.log(`Creating plugins directory: ${pluginsDir}`);
    fs.mkdirSync(pluginsDir, { recursive: true });
  }

  // Copy the plugin
  try {
    fs.copyFileSync(sourceFile, destFile);
    console.log("Plugin installed successfully!\n");
    console.log("Next steps:");
    console.log("1. Open (or restart) Roblox Studio");
    console.log("2. The MCP Bridge button should appear in the Studio toolbar");
    console.log("3. Click it to start the bridge connection");
    console.log(`4. Start the MCP server: npx roblox-studio-mcp`);
  } catch (error) {
    console.error(`Failed to install plugin: ${error}`);
    console.log("\nManual installation:");
    console.log(`Copy the file from:\n  ${sourceFile}`);
    console.log(`To:\n  ${destFile}`);
    process.exit(1);
  }
}

main();
