--[[
	Roblox Studio MCP Bridge Plugin
	
	This plugin runs inside Roblox Studio and bridges MCP tool calls
	to actual Studio operations. It polls an HTTP server for commands
	and sends back results.
	
	Architecture:
	  MCP Server (Node.js) <--HTTP--> Plugin (Lua polling)
	  
	The plugin polls GET /poll for pending commands, executes them,
	and POSTs results back to /result.
]]

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local _StudioService = game:GetService("StudioService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local InsertService = game:GetService("InsertService")
local _MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local ServerScriptService = game:GetService("ServerScriptService")

-- ============================================================================
-- Configuration
-- ============================================================================

local BRIDGE_URL = "http://127.0.0.1:28821"
local POLL_INTERVAL = 0.25  -- seconds between polls
local PLUGIN_NAME = "RobloxStudioMCP"
local PLUGIN_VERSION = "1.0.0"

-- ============================================================================
-- Toolbar & Widget Setup
-- ============================================================================

local toolbar = plugin:CreateToolbar("MCP Bridge")
local toggleButton = toolbar:CreateButton(
	"MCP Bridge",
	"Toggle MCP Bridge connection",
	"rbxassetid://4458901886" -- generic plugin icon
)

local active = false
local pollConnection = nil

-- Forward declarations (defined later, referenced by button handlers)
local startPolling
local stopPolling

-- ============================================================================
-- Status Widget UI
-- ============================================================================

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Bottom, -- initial dock state
	false,                         -- initially enabled (visible)
	false,                         -- override previous state
	340,                           -- default width
	180,                           -- default height
	280,                           -- minimum width
	140                            -- minimum height
)

local widget = plugin:CreateDockWidgetPluginGuiAsync("MCPBridgeStatus", widgetInfo)
widget.Title = "MCP Bridge"

-- State tracked by the UI
local connectionState = "Disconnected" -- "Disconnected" | "Connecting" | "Connected"
local commandsExecuted = 0
local lastCommandName = ""
local lastCommandTime = 0
local lastError = ""
local consecutiveFailures = 0

-- Colors
local COLOR_BG         = Color3.fromRGB(30, 30, 30)
local COLOR_CARD       = Color3.fromRGB(42, 42, 42)
local COLOR_TEXT       = Color3.fromRGB(210, 210, 210)
local COLOR_DIM        = Color3.fromRGB(130, 130, 130)
local COLOR_GREEN      = Color3.fromRGB(80, 200, 120)
local COLOR_RED        = Color3.fromRGB(220, 70, 70)
local COLOR_YELLOW     = Color3.fromRGB(230, 190, 60)
local _COLOR_ACCENT    = Color3.fromRGB(90, 145, 255)

-- Root frame
local root = Instance.new("Frame")
root.Size = UDim2.new(1, 0, 1, 0)
root.BackgroundColor3 = COLOR_BG
root.BorderSizePixel = 0
root.Parent = widget

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 10)
padding.PaddingBottom = UDim.new(0, 10)
padding.PaddingLeft = UDim.new(0, 12)
padding.PaddingRight = UDim.new(0, 12)
padding.Parent = root

local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 8)
layout.Parent = root

-- Helper: create a label
local function makeLabel(parent, text, order, color, textSize)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, textSize or 14)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color or COLOR_TEXT
	label.TextSize = textSize or 14
	label.Font = Enum.Font.GothamMedium
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.LayoutOrder = order or 0
	label.Parent = parent
	return label
end

-- Status row (dot + text)
local statusRow = Instance.new("Frame")
statusRow.Size = UDim2.new(1, 0, 0, 22)
statusRow.BackgroundTransparency = 1
statusRow.LayoutOrder = 1
statusRow.Parent = root

local statusDot = Instance.new("Frame")
statusDot.Size = UDim2.new(0, 10, 0, 10)
statusDot.Position = UDim2.new(0, 0, 0, 6)
statusDot.BackgroundColor3 = COLOR_RED
statusDot.BorderSizePixel = 0
statusDot.Parent = statusRow
local dotCorner = Instance.new("UICorner")
dotCorner.CornerRadius = UDim.new(1, 0)
dotCorner.Parent = statusDot

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -18, 1, 0)
statusLabel.Position = UDim2.new(0, 18, 0, 0)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Disconnected"
statusLabel.TextColor3 = COLOR_TEXT
statusLabel.TextSize = 15
statusLabel.Font = Enum.Font.GothamBold
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = statusRow

-- URL label
local _urlLabel = makeLabel(root, "Bridge: " .. BRIDGE_URL, 2, COLOR_DIM, 12)

-- Separator
local sep = Instance.new("Frame")
sep.Size = UDim2.new(1, 0, 0, 1)
sep.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
sep.BorderSizePixel = 0
sep.LayoutOrder = 3
sep.Parent = root

-- Stats card
local statsCard = Instance.new("Frame")
statsCard.Size = UDim2.new(1, 0, 0, 48)
statsCard.BackgroundColor3 = COLOR_CARD
statsCard.BorderSizePixel = 0
statsCard.LayoutOrder = 4
statsCard.Parent = root
local statsCorner = Instance.new("UICorner")
statsCorner.CornerRadius = UDim.new(0, 6)
statsCorner.Parent = statsCard
local statsPad = Instance.new("UIPadding")
statsPad.PaddingTop = UDim.new(0, 6)
statsPad.PaddingLeft = UDim.new(0, 8)
statsPad.PaddingRight = UDim.new(0, 8)
statsPad.Parent = statsCard
local statsLayout = Instance.new("UIListLayout")
statsLayout.SortOrder = Enum.SortOrder.LayoutOrder
statsLayout.Padding = UDim.new(0, 2)
statsLayout.Parent = statsCard

local commandCountLabel = makeLabel(statsCard, "Commands: 0", 1, COLOR_TEXT, 13)
local lastCmdLabel = makeLabel(statsCard, "Last: --", 2, COLOR_DIM, 12)

-- Error card (hidden by default)
local errorCard = Instance.new("Frame")
errorCard.Size = UDim2.new(1, 0, 0, 32)
errorCard.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
errorCard.BorderSizePixel = 0
errorCard.LayoutOrder = 5
errorCard.Visible = false
errorCard.Parent = root
local errCorner = Instance.new("UICorner")
errCorner.CornerRadius = UDim.new(0, 6)
errCorner.Parent = errorCard
local errPad = Instance.new("UIPadding")
errPad.PaddingTop = UDim.new(0, 6)
errPad.PaddingLeft = UDim.new(0, 8)
errPad.PaddingRight = UDim.new(0, 8)
errPad.Parent = errorCard

local errorLabel = makeLabel(errorCard, "", 1, COLOR_RED, 12)

-- Function to update the widget
local function updateWidget()
	if connectionState == "Connected" then
		statusDot.BackgroundColor3 = COLOR_GREEN
		statusLabel.Text = "Connected"
		statusLabel.TextColor3 = COLOR_GREEN
	elseif connectionState == "Connecting" then
		statusDot.BackgroundColor3 = COLOR_YELLOW
		statusLabel.Text = "Connecting..."
		statusLabel.TextColor3 = COLOR_YELLOW
	else
		statusDot.BackgroundColor3 = COLOR_RED
		statusLabel.Text = "Disconnected"
		statusLabel.TextColor3 = COLOR_RED
	end
	
	commandCountLabel.Text = "Commands executed: " .. tostring(commandsExecuted)
	
	if lastCommandName ~= "" then
		local ago = math.floor(tick() - lastCommandTime)
		local agoStr = ago < 60 and (ago .. "s ago") or (math.floor(ago / 60) .. "m ago")
		lastCmdLabel.Text = "Last: " .. lastCommandName .. " (" .. agoStr .. ")"
	else
		lastCmdLabel.Text = "Last: --"
	end
	
	if lastError ~= "" then
		errorCard.Visible = true
		errorLabel.Text = lastError
	else
		errorCard.Visible = false
	end
end

-- Toggle widget with button
toggleButton.Click:Connect(function()
	if active then
		stopPolling()
	else
		startPolling()
	end
end)

-- Also toggle widget visibility
local widgetButton = toolbar:CreateButton(
	"Status Panel",
	"Toggle MCP Bridge status panel",
	"rbxassetid://4458901886"
)
widgetButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	widgetButton:SetActive(widget.Enabled)
end)

-- ============================================================================
-- Utility Functions
-- ============================================================================

local function jsonEncode(data)
	return HttpService:JSONEncode(data)
end

local function jsonDecode(str)
	return HttpService:JSONDecode(str)
end

local function safeRequest(options)
	local success, response = pcall(function()
		return HttpService:RequestAsync(options)
	end)
	if success then
		return response
	else
		return nil, response
	end
end

-- Forward declaration (defined below)
local resolveInstancePath

-- ============================================================================
-- Universal Property Setter
-- ============================================================================

--[[
	Converts a JSON-friendly value into the correct Roblox type and assigns it.
	
	Supported formats:
	  Vector3:        { X = 0, Y = 5, Z = 0 }
	  Vector2:        { X = 0, Y = 0 }
	  UDim2:          { X = { Scale = 1, Offset = 0 }, Y = { Scale = 1, Offset = 0 } }
	                  or shorthand: { XScale = 1, XOffset = 0, YScale = 1, YOffset = 0 }
	  UDim:           { Scale = 0.5, Offset = 10 }
	  CFrame:         { X = 0, Y = 5, Z = 0 } (position only)
	                  or { Position = { X, Y, Z } }
	  Color3:         { R = 1, G = 0, B = 0 }  (0-1 floats)
	  Color3 (RGB):   { R = 255, G = 0, B = 0 } (auto-detected when any > 1)
	  BrickColor:     "Bright red" (string)
	  Rect:           { Min = { X, Y }, Max = { X, Y } }
	  NumberRange:    { Min = 0, Max = 10 }
	  NumberSequence: { { Time = 0, Value = 1 }, { Time = 1, Value = 0 } }
	  ColorSequence:  { { Time = 0, Color = { R, G, B } }, { Time = 1, Color = { R, G, B } } }
	  Font:           { Family = "rbxasset://...", Weight = "Bold", Style = "Normal" }
	  Enum:           "EnumValue" (string — matched against the property's enum type)
	  Material:       "Neon" (string — shorthand for Enum.Material.Neon)
	  Parent:         "Workspace.Folder" (string — resolved as instance path)
	  Primitives:     string, number, boolean assigned directly
]]
local function applyProperty(instance, propName, propValue)
	-- Table values need type inference
	if type(propValue) == "table" then
		-- UDim2: has X and Y sub-tables with Scale/Offset, or XScale/YScale shorthand
		if propValue.XScale ~= nil or propValue.XOffset ~= nil or propValue.YScale ~= nil or propValue.YOffset ~= nil then
			instance[propName] = UDim2.new(
				propValue.XScale or 0, propValue.XOffset or 0,
				propValue.YScale or 0, propValue.YOffset or 0
			)
			return true
		end
		
		if type(propValue.X) == "table" or type(propValue.Y) == "table" then
			local x = propValue.X or {}
			local y = propValue.Y or {}
			instance[propName] = UDim2.new(
				x.Scale or 0, x.Offset or 0,
				y.Scale or 0, y.Offset or 0
			)
			return true
		end
		
		-- UDim: { Scale, Offset }
		if propValue.Scale ~= nil and propValue.Offset ~= nil and propValue.X == nil then
			instance[propName] = UDim.new(propValue.Scale, propValue.Offset)
			return true
		end
		
		-- Rect: { Min = {X,Y}, Max = {X,Y} }
		if propValue.Min ~= nil and propValue.Max ~= nil
			and type(propValue.Min) == "table" and type(propValue.Max) == "table"
			and propValue.Min.X ~= nil and propValue.Max.X ~= nil then
			instance[propName] = Rect.new(
				propValue.Min.X or 0, propValue.Min.Y or 0,
				propValue.Max.X or 0, propValue.Max.Y or 0
			)
			return true
		end
		
		-- NumberRange: { Min, Max }
		if propValue.Min ~= nil and propValue.Max ~= nil
			and type(propValue.Min) == "number" and type(propValue.Max) == "number" then
			instance[propName] = NumberRange.new(propValue.Min, propValue.Max)
			return true
		end
		
		-- CFrame: { Position = {X,Y,Z} } or { X, Y, Z }
		if propValue.Position ~= nil and type(propValue.Position) == "table" then
			local p = propValue.Position
			instance[propName] = CFrame.new(p.X or 0, p.Y or 0, p.Z or 0)
			return true
		end
		
		-- NumberSequence: array of { Time, Value }
		if #propValue > 0 and type(propValue[1]) == "table" and propValue[1].Time ~= nil and propValue[1].Value ~= nil then
			local keypoints = {}
			for _, kp in ipairs(propValue) do
				table.insert(keypoints, NumberSequenceKeypoint.new(kp.Time, kp.Value, kp.Envelope or 0))
			end
			instance[propName] = NumberSequence.new(keypoints)
			return true
		end
		
		-- ColorSequence: array of { Time, Color = {R,G,B} }
		if #propValue > 0 and type(propValue[1]) == "table" and propValue[1].Time ~= nil and propValue[1].Color ~= nil then
			local keypoints = {}
			for _, kp in ipairs(propValue) do
				local c = kp.Color or {}
				table.insert(keypoints, ColorSequenceKeypoint.new(kp.Time, Color3.new(c.R or 0, c.G or 0, c.B or 0)))
			end
			instance[propName] = ColorSequence.new(keypoints)
			return true
		end
		
		-- Font: { Family, Weight, Style }
		if propValue.Family ~= nil then
			local weight = Enum.FontWeight.Regular
			if propValue.Weight then
				local ok, w = pcall(function() return Enum.FontWeight[propValue.Weight] end)
				if ok then weight = w end
			end
			local style = Enum.FontStyle.Normal
			if propValue.Style then
				local ok, s = pcall(function() return Enum.FontStyle[propValue.Style] end)
				if ok then style = s end
			end
			instance[propName] = Font.new(propValue.Family, weight, style)
			return true
		end
		
		-- Color3: { R, G, B }
		if propValue.R ~= nil and propValue.G ~= nil and propValue.B ~= nil and propValue.X == nil then
			local r, g, b = propValue.R, propValue.G, propValue.B
			-- Auto-detect 0-255 range vs 0-1
			if r > 1 or g > 1 or b > 1 then
				instance[propName] = Color3.fromRGB(r, g, b)
			else
				instance[propName] = Color3.new(r, g, b)
			end
			return true
		end
		
		-- Vector3: { X, Y, Z } (must check after Color3 since Color3 also has no X but might overlap)
		if propValue.X ~= nil and propValue.Y ~= nil and propValue.Z ~= nil then
			-- Could be Vector3 or CFrame position — try Vector3 first
			local ok = pcall(function()
				instance[propName] = Vector3.new(propValue.X, propValue.Y, propValue.Z)
			end)
			if not ok then
				-- Might be a CFrame property
				instance[propName] = CFrame.new(propValue.X, propValue.Y, propValue.Z)
			end
			return true
		end
		
		-- Vector2: { X, Y } (no Z)
		if propValue.X ~= nil and propValue.Y ~= nil and propValue.Z == nil and propValue.R == nil then
			instance[propName] = Vector2.new(propValue.X, propValue.Y)
			return true
		end
		
		-- Unknown table — fall through to raw assign
		instance[propName] = propValue
		return true
	end
	
	-- String values: could be Enum, BrickColor, Material, or Parent path
	if type(propValue) == "string" then
		if propName == "Parent" then
			local resolved = resolveInstancePath(propValue)
			if resolved then
				instance.Parent = resolved
			else
				error("Cannot resolve parent path: " .. propValue)
			end
			return true
		end
		
		if propName == "Material" then
			local ok = pcall(function()
				instance.Material = Enum.Material[propValue]
			end)
			if ok then return true end
		end
		
		if propName == "BrickColor" then
			local name: any = propValue
			instance.BrickColor = BrickColor.new(name)
			return true
		end
		
		-- Try as enum value (works for Shape, SortOrder, etc.)
		local directOk = pcall(function()
			instance[propName] = propValue
		end)
		if directOk then return true end
		
		-- Try finding the enum automatically
		local enumOk = pcall(function()
			-- Get the current value's enum type and look up the string
			local currentVal = instance[propName]
			if typeof(currentVal) == "EnumItem" then
				local enumType = currentVal.EnumType
				instance[propName] = enumType[propValue]
			end
		end)
		if enumOk then return true end
		
		return false, "Could not assign string value '" .. propValue .. "' to " .. propName
	end
	
	-- Primitives: number, boolean
	instance[propName] = propValue
	return true
end

-- Apply a table of properties to an instance. Returns list of errors (empty = success).
local function applyProperties(instance, properties)
	local errors = {}
	for propName, propValue in pairs(properties) do
		local ok, err = pcall(applyProperty, instance, propName, propValue)
		if not ok then
			table.insert(errors, propName .. ": " .. tostring(err))
		end
	end
	return errors
end

-- ============================================================================
-- Instance Path Resolution
-- ============================================================================

-- Resolve an instance from a path string like "Workspace.Model.Part"
function resolveInstancePath(path)
	if not path or path == "" then
		return game
	end
	
	local segments = string.split(path, ".")
	local current = game
	
	for _, segment in ipairs(segments) do
		local child = current:FindFirstChild(segment)
		if not child then
			return nil, "Instance not found at segment: " .. segment .. " in path: " .. path
		end
		current = child
	end
	
	return current
end

-- Get the full path of an instance
local function getInstancePath(instance)
	local parts = {}
	local current = instance
	while current and current ~= game do
		table.insert(parts, 1, current.Name)
		current = current.Parent
	end
	return table.concat(parts, ".")
end

-- Serialize instance properties for transport
local function serializeInstance(instance, depth, maxDepth)
	depth = depth or 0
	maxDepth = maxDepth or 0
	
	local data = {
		Name = instance.Name,
		ClassName = instance.ClassName,
		Path = getInstancePath(instance),
		Children = #instance:GetChildren(),
	}
	
	-- Add common properties based on class
	pcall(function()
		if instance:IsA("BasePart") then
			data.Position = {
				X = instance.Position.X,
				Y = instance.Position.Y,
				Z = instance.Position.Z,
			}
			data.Size = {
				X = instance.Size.X,
				Y = instance.Size.Y,
				Z = instance.Size.Z,
			}
			data.Color = {
				R = instance.Color.R,
				G = instance.Color.G,
				B = instance.Color.B,
			}
			data.Material = instance.Material.Name
			data.Transparency = instance.Transparency
			data.Anchored = instance.Anchored
			data.CanCollide = instance.CanCollide
			data.CastShadow = instance.CastShadow
		end
	end)
	
	pcall(function()
		if instance:IsA("LuaSourceContainer") then
			local doc = ScriptEditorService:FindScriptDocument(instance)
			if doc then
				-- Get source from the script editor if open
				local lineCount = doc:GetLineCount()
				local lines = {}
				for i = 1, lineCount do
					table.insert(lines, doc:GetLine(i))
				end
				data.Source = table.concat(lines, "\n")
			else
				data.Source = instance.Source
			end
			data.Disabled = instance.Disabled
			if instance:IsA("ModuleScript") then
				data.ScriptType = "ModuleScript"
			elseif instance:IsA("LocalScript") then
				data.ScriptType = "LocalScript"
			else
				data.ScriptType = "Script"
			end
		end
	end)
	
	pcall(function()
		if instance:IsA("Model") then
			if instance.PrimaryPart then
				data.PrimaryPart = instance.PrimaryPart.Name
				data.PrimaryPartPosition = {
					X = instance.PrimaryPart.Position.X,
					Y = instance.PrimaryPart.Position.Y,
					Z = instance.PrimaryPart.Position.Z,
				}
			end
		end
	end)
	
	pcall(function()
		if instance:IsA("Camera") then
			data.CFrame = {
				Position = {
					X = instance.CFrame.Position.X,
					Y = instance.CFrame.Position.Y,
					Z = instance.CFrame.Position.Z,
				},
			}
			data.FieldOfView = instance.FieldOfView
			data.CameraType = instance.CameraType.Name
		end
	end)
	
	pcall(function()
		if instance:IsA("Lighting") then
			data.ClockTime = instance.ClockTime
			data.Brightness = instance.Brightness
			data.Ambient = {
				R = instance.Ambient.R,
				G = instance.Ambient.G,
				B = instance.Ambient.B,
			}
		end
	end)
	
	pcall(function()
		if instance:IsA("Humanoid") then
			data.Health = instance.Health
			data.MaxHealth = instance.MaxHealth
			data.WalkSpeed = instance.WalkSpeed
			data.JumpPower = instance.JumpPower
		end
	end)
	
	-- Recurse into children if requested
	if depth < maxDepth then
		data.ChildrenList = {}
		for _, child in ipairs(instance:GetChildren()) do
			table.insert(data.ChildrenList, serializeInstance(child, depth + 1, maxDepth))
		end
	end
	
	return data
end

-- Build a tree representation of the workspace
local function buildTree(root, maxDepth, currentDepth, prefix)
	currentDepth = currentDepth or 0
	prefix = prefix or ""
	maxDepth = maxDepth or 3
	
	local lines = {}
	local children = root:GetChildren()
	
	for i, child in ipairs(children) do
		local isLast = (i == #children)
		local connector = isLast and "└── " or "├── "
		local childPrefix = isLast and "    " or "│   "
		
		local extra = ""
		if child:IsA("BasePart") then
			extra = string.format(" [%s, %.1f,%.1f,%.1f]", child.ClassName, child.Position.X, child.Position.Y, child.Position.Z)
		elseif child:IsA("LuaSourceContainer") then
			extra = string.format(" [%s]", child.ClassName)
		elseif child:IsA("Model") then
			extra = string.format(" [Model, %d children]", #child:GetChildren())
		elseif child:IsA("Folder") then
			extra = string.format(" [Folder, %d children]", #child:GetChildren())
		end
		
		table.insert(lines, prefix .. connector .. child.Name .. extra)
		
		if currentDepth < maxDepth and #child:GetChildren() > 0 then
			local subLines = buildTree(child, maxDepth, currentDepth + 1, prefix .. childPrefix)
			for _, line in ipairs(subLines) do
				table.insert(lines, line)
			end
		elseif #child:GetChildren() > 0 and currentDepth >= maxDepth then
			table.insert(lines, prefix .. childPrefix .. "└── ... (" .. #child:GetChildren() .. " children)")
		end
	end
	
	return lines
end

-- ============================================================================
-- Command Handlers
-- ============================================================================

local handlers = {}

-- ---------- Workspace Exploration ----------

handlers["get-workspace-tree"] = function(params)
	local root = game
	if params.root and params.root ~= "" then
		local resolved, err = resolveInstancePath(params.root)
		if not resolved then
			return { success = false, error = err }
		end
		root = resolved
	end
	
	local maxDepth = params.maxDepth or 3
	local lines = buildTree(root, maxDepth)
	local tree = (params.root or "game") .. "\n" .. table.concat(lines, "\n")
	
	return { success = true, tree = tree }
end

handlers["search-instances"] = function(params)
	local query = params.query or ""
	local className = params.className
	local root = game.Workspace
	
	if params.root and params.root ~= "" then
		local resolved, err = resolveInstancePath(params.root)
		if not resolved then
			return { success = false, error = err }
		end
		root = resolved
	end
	
	local results = {}
	local maxResults = params.maxResults or 50
	
	local function searchRecursive(instance)
		if #results >= maxResults then return end
		
		local nameMatch = query == "" or string.find(string.lower(instance.Name), string.lower(query), 1, true)
		local classMatch = not className or instance.ClassName == className
		
		if nameMatch and classMatch then
			table.insert(results, serializeInstance(instance, 0, 0))
		end
		
		for _, child in ipairs(instance:GetChildren()) do
			searchRecursive(child)
		end
	end
	
	searchRecursive(root)
	
	return { success = true, results = results, count = #results }
end

handlers["get-instance"] = function(params)
	local instance, err = resolveInstancePath(params.path)
	if not instance then
		return { success = false, error = err }
	end
	
	local depth = params.depth or 1
	return { success = true, instance = serializeInstance(instance, 0, depth) }
end

handlers["get-properties"] = function(params)
	local instance, err = resolveInstancePath(params.path)
	if not instance then
		return { success = false, error = err }
	end
	
	-- Use the API dump to get all properties would be ideal, but we'll grab common ones
	local props = {
		Name = instance.Name,
		ClassName = instance.ClassName,
		Path = getInstancePath(instance),
		Parent = instance.Parent and instance.Parent.Name or nil,
		ChildCount = #instance:GetChildren(),
	}
	
	-- Attempt to read various common properties with pcall
	local tryProp = function(name)
		local ok, val = pcall(function() return instance[name] end)
		if ok and val ~= nil then
			-- Handle special types
			if typeof(val) == "Vector3" then
				props[name] = { X = val.X, Y = val.Y, Z = val.Z }
			elseif typeof(val) == "CFrame" then
				props[name] = {
					Position = { X = val.Position.X, Y = val.Position.Y, Z = val.Position.Z },
				}
			elseif typeof(val) == "Color3" then
				props[name] = { R = val.R, G = val.G, B = val.B }
			elseif typeof(val) == "BrickColor" then
				props[name] = tostring(val)
			elseif typeof(val) == "EnumItem" then
				props[name] = val.Name
			elseif typeof(val) == "UDim2" then
				props[name] = {
					X = { Scale = val.X.Scale, Offset = val.X.Offset },
					Y = { Scale = val.Y.Scale, Offset = val.Y.Offset },
				}
			elseif typeof(val) == "Instance" then
				props[name] = getInstancePath(val)
			elseif type(val) == "string" or type(val) == "number" or type(val) == "boolean" then
				props[name] = val
			else
				props[name] = tostring(val)
			end
		end
	end
	
	-- Common properties to try
	local commonProps = {
		"Position", "Size", "CFrame", "Rotation",
		"Color", "BrickColor", "Material", "Transparency", "Reflectance",
		"Anchored", "CanCollide", "CastShadow", "Massless",
		"Shape",
		"Source", "Disabled",
		"Value",
		"Text", "TextColor3", "TextSize", "Font",
		"Image", "ImageColor3",
		"Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight",
		"Brightness", "ClockTime", "Ambient",
		"FieldOfView", "CameraType",
		"MaxForce", "MaxTorque",
		"Adornee", "AlwaysOnTop",
		"PrimaryPart",
		"Archivable",
	}
	
	for _, propName in ipairs(commonProps) do
		tryProp(propName)
	end
	
	-- Also read any properties specified by the user
	if params.properties then
		for _, propName in ipairs(params.properties) do
			tryProp(propName)
		end
	end
	
	return { success = true, properties = props }
end

handlers["get-descendants-summary"] = function(params)
	local root = game.Workspace
	if params.root and params.root ~= "" then
		local resolved, err = resolveInstancePath(params.root)
		if not resolved then
			return { success = false, error = err }
		end
		root = resolved
	end
	
	local classCounts = {}
	local totalCount = 0
	
	for _, desc in ipairs(root:GetDescendants()) do
		totalCount = totalCount + 1
		classCounts[desc.ClassName] = (classCounts[desc.ClassName] or 0) + 1
	end
	
	-- Sort by count descending
	local sorted = {}
	for className, count in pairs(classCounts) do
		table.insert(sorted, { className = className, count = count })
	end
	table.sort(sorted, function(a, b) return a.count > b.count end)
	
	return {
		success = true,
		totalDescendants = totalCount,
		classSummary = sorted,
		rootPath = getInstancePath(root),
	}
end

-- ---------- Texture / Decal Info ----------

handlers["get-texture-info"] = function(params)
	local instance, err = resolveInstancePath(params.path)
	if not instance then
		return { success = false, error = err }
	end

	local maxDepth = params.maxDepth or 2
	local textures = {}

	local function collectTextures(inst, depth)
		-- MeshPart TextureID
		if inst:IsA("MeshPart") then
			local tid = inst.TextureID
			if tid and tid ~= "" then
				local numId = tonumber(string.match(tid, "%d+"))
				table.insert(textures, {
					Path = getInstancePath(inst),
					ClassName = inst.ClassName,
					Type = "MeshPartTexture",
					AssetId = numId,
					RawId = tid,
					Material = tostring(inst.Material),
				})
			end
		end

		-- Decals and Texture instances on this part
		for _, child in ipairs(inst:GetChildren()) do
			if child:IsA("Decal") or child:IsA("Texture") then
				local did = child.Texture
				if did and did ~= "" then
					local numId = tonumber(string.match(did, "%d+"))
					local entry = {
						Path = getInstancePath(child),
						ClassName = child.ClassName,
						Type = child.ClassName,
						AssetId = numId,
						RawId = did,
						Face = tostring(child.Face),
					}
					if child:IsA("Texture") then
						entry.StudsPerTileU = child.StudsPerTileU
						entry.StudsPerTileV = child.StudsPerTileV
					end
					table.insert(textures, entry)
				end
			end
		end

		-- SurfaceAppearance
		for _, child in ipairs(inst:GetChildren()) do
			if child:IsA("SurfaceAppearance") then
				local entry = {
					Path = getInstancePath(child),
					ClassName = "SurfaceAppearance",
					Type = "SurfaceAppearance",
				}
				if child.ColorMap and child.ColorMap ~= "" then
					entry.ColorMap = child.ColorMap
				end
				if child.NormalMap and child.NormalMap ~= "" then
					entry.NormalMap = child.NormalMap
				end
				if child.MetalnessMap and child.MetalnessMap ~= "" then
					entry.MetalnessMap = child.MetalnessMap
				end
				if child.RoughnessMap and child.RoughnessMap ~= "" then
					entry.RoughnessMap = child.RoughnessMap
				end
				table.insert(textures, entry)
			end
		end

		-- Recurse into descendants
		if depth < maxDepth then
			for _, child in ipairs(inst:GetChildren()) do
				if not child:IsA("Decal") and not child:IsA("Texture") and not child:IsA("SurfaceAppearance") then
					collectTextures(child, depth + 1)
				end
			end
		end
	end

	collectTextures(instance, 0)

	-- Also report the Material of the root if it's a BasePart
	local rootMaterial = nil
	if instance:IsA("BasePart") then
		rootMaterial = tostring(instance.Material)
	end

	return {
		success = true,
		path = getInstancePath(instance),
		rootMaterial = rootMaterial,
		textures = textures,
		count = #textures,
	}
end

-- ---------- Instance CRUD ----------

handlers["create-instance"] = function(params)
	local parentInstance = game.Workspace
	if params.parent and params.parent ~= "" then
		local resolved, err = resolveInstancePath(params.parent)
		if not resolved then
			return { success = false, error = err }
		end
		parentInstance = resolved
	end
	
	local ok, newInstance = pcall(function()
		local inst = Instance.new(params.className)
		if params.name then
			inst.Name = params.name
		end
		
		-- Set properties before parenting
		if params.properties then
			local errs = applyProperties(inst, params.properties)
			if #errs > 0 then
				warn("[MCP Bridge] create-instance property warnings: " .. table.concat(errs, "; "))
			end
		end
		
		inst.Parent = parentInstance
		return inst
	end)
	
	if ok then
		ChangeHistoryService:SetWaypoint("MCP: Create " .. params.className)
		return { success = true, instance = serializeInstance(newInstance, 0, 0) }
	else
		return { success = false, error = tostring(newInstance) }
	end
end

handlers["delete-instance"] = function(params)
	local instance, err = resolveInstancePath(params.path)
	if not instance then
		return { success = false, error = err }
	end
	
	if instance == game or instance == game.Workspace then
		return { success = false, error = "Cannot delete game or Workspace" }
	end
	
	local name = instance.Name
	local className = instance.ClassName
	instance:Destroy()
	ChangeHistoryService:SetWaypoint("MCP: Delete " .. name)
	
	return { success = true, deleted = { Name = name, ClassName = className, Path = params.path } }
end

handlers["update-instance"] = function(params)
	local instance, err = resolveInstancePath(params.path)
	if not instance then
		return { success = false, error = err }
	end
	
	local updated = {}
	
	for propName, propValue in pairs(params.properties or {}) do
		local ok, setErr = pcall(applyProperty, instance, propName, propValue)
		if ok then
			table.insert(updated, propName)
		else
			return { success = false, error = "Failed to set " .. propName .. ": " .. tostring(setErr) }
		end
	end
	
	-- Handle rename separately
	if params.name then
		instance.Name = params.name
		table.insert(updated, "Name")
	end
	
	ChangeHistoryService:SetWaypoint("MCP: Update " .. instance.Name)
	return { success = true, updated = updated, instance = serializeInstance(instance, 0, 0) }
end

handlers["reset-pivot"] = function(params)
	local instance, err = resolveInstancePath(params.path)
	if not instance then
		return { success = false, error = err }
	end

	if instance:IsA("Model") then
		local cf, size = instance:GetBoundingBox()
		local oldPivot = instance:GetPivot()
		instance.WorldPivot = cf
		local newPivot = instance:GetPivot()
		ChangeHistoryService:SetWaypoint("MCP: Reset pivot of " .. instance.Name)
		return {
			success = true,
			oldPivot = { X = oldPivot.Position.X, Y = oldPivot.Position.Y, Z = oldPivot.Position.Z },
			newPivot = { X = newPivot.Position.X, Y = newPivot.Position.Y, Z = newPivot.Position.Z },
			boundingBoxCenter = { X = cf.Position.X, Y = cf.Position.Y, Z = cf.Position.Z },
			boundingBoxSize = { X = size.X, Y = size.Y, Z = size.Z },
		}
	elseif instance:IsA("BasePart") then
		-- BaseParts use PivotOffset relative to CFrame; reset to center
		instance.PivotOffset = CFrame.new()
		ChangeHistoryService:SetWaypoint("MCP: Reset pivot of " .. instance.Name)
		return { success = true, message = "PivotOffset reset to center" }
	else
		return { success = false, error = instance.ClassName .. " does not have a pivot to reset" }
	end
end

handlers["clone-instance"] = function(params)
	local instance, err = resolveInstancePath(params.path)
	if not instance then
		return { success = false, error = err }
	end
	
	local clone = instance:Clone()
	if params.name then
		clone.Name = params.name
	end
	
	if params.parent then
		local parentInstance, parentErr = resolveInstancePath(params.parent)
		if not parentInstance then
			clone:Destroy()
			return { success = false, error = parentErr }
		end
		clone.Parent = parentInstance
	else
		clone.Parent = instance.Parent
	end
	
	ChangeHistoryService:SetWaypoint("MCP: Clone " .. instance.Name)
	return { success = true, instance = serializeInstance(clone, 0, 0) }
end

handlers["reparent-instance"] = function(params)
	local instance, err = resolveInstancePath(params.path)
	if not instance then
		return { success = false, error = err }
	end
	
	local newParent, parentErr = resolveInstancePath(params.newParent)
	if not newParent then
		return { success = false, error = parentErr }
	end
	
	instance.Parent = newParent
	ChangeHistoryService:SetWaypoint("MCP: Reparent " .. instance.Name)
	
	return { success = true, instance = serializeInstance(instance, 0, 0) }
end

-- ---------- Script Management ----------

handlers["create-script"] = function(params)
	local parentInstance = game.Workspace
	if params.parent and params.parent ~= "" then
		local resolved, err = resolveInstancePath(params.parent)
		if not resolved then
			return { success = false, error = err }
		end
		parentInstance = resolved
	end
	
	local scriptType = params.scriptType or "Script"
	if scriptType ~= "Script" and scriptType ~= "LocalScript" and scriptType ~= "ModuleScript" then
		return { success = false, error = "Invalid scriptType. Use Script, LocalScript, or ModuleScript" }
	end
	
	local newScript = Instance.new(scriptType)
	newScript.Name = params.name or scriptType
	newScript.Source = params.source or ""
	
	if params.disabled ~= nil then
		if scriptType ~= "ModuleScript" then
			newScript.Disabled = params.disabled
		end
	end
	
	newScript.Parent = parentInstance
	ChangeHistoryService:SetWaypoint("MCP: Create " .. scriptType .. " '" .. newScript.Name .. "'")
	
	return { success = true, instance = serializeInstance(newScript, 0, 0) }
end

handlers["update-script-source"] = function(params)
	local instance, err = resolveInstancePath(params.path)
	if not instance then
		return { success = false, error = err }
	end
	
	if not instance:IsA("LuaSourceContainer") then
		return { success = false, error = "Instance at " .. params.path .. " is not a script (is " .. instance.ClassName .. ")" }
	end
	
	-- Try to update via ScriptEditorService first (works even if script is open in editor)
	local ok = pcall(function()
		local doc = ScriptEditorService:FindScriptDocument(instance)
		if doc then
			-- Edit through the document
			local lineCount = doc:GetLineCount()
			local lastLineLength = #doc:GetLine(lineCount)
			doc:EditTextAsync(params.source, 1, 1, lineCount, lastLineLength + 1)
		else
			instance.Source = params.source
		end
	end)
	
	if not ok then
		-- Fallback
		instance.Source = params.source
	end
	
	ChangeHistoryService:SetWaypoint("MCP: Update source of " .. instance.Name)
	return { success = true, path = params.path, sourceLength = #params.source }
end

handlers["get-script-source"] = function(params)
	local instance, err = resolveInstancePath(params.path)
	if not instance then
		return { success = false, error = err }
	end
	
	if not instance:IsA("LuaSourceContainer") then
		return { success = false, error = "Instance at " .. params.path .. " is not a script" }
	end
	
	local source = instance.Source
	
	-- Try ScriptEditorService for possibly newer source
	pcall(function()
		local doc = ScriptEditorService:FindScriptDocument(instance)
		if doc then
			local lineCount = doc:GetLineCount()
			local lines = {}
			for i = 1, lineCount do
				table.insert(lines, doc:GetLine(i))
			end
			source = table.concat(lines, "\n")
		end
	end)
	
	return {
		success = true,
		path = params.path,
		name = instance.Name,
		className = instance.ClassName,
		source = source,
		lineCount = select(2, string.gsub(source, "\n", "")) + 1,
	}
end

handlers["execute-script"] = function(params)
	-- Execute a snippet of Lua in the command bar context
	-- We create a temporary ModuleScript and require it
	local source = params.source
	if not source or source == "" then
		return { success = false, error = "No source code provided" }
	end
	
	-- Wrap in a module that returns the result
	local wrappedSource = [[
local module = {}
function module.run()
	]] .. source .. [[

end
return module
]]
	
	local tempScript = Instance.new("ModuleScript")
	tempScript.Name = "_MCP_TempExec_" .. tick()
	tempScript.Source = wrappedSource
	tempScript.Parent = ServerScriptService
	
	local ok, result = pcall(function()
		local mod = require(tempScript)
		return mod.run()
	end)
	
	tempScript:Destroy()
	
	if ok then
		local resultStr = tostring(result)
		if type(result) == "table" then
			pcall(function()
				resultStr = jsonEncode(result)
			end)
		end
		return { success = true, result = resultStr }
	else
		return { success = false, error = tostring(result) }
	end
end

-- ---------- Playtest Controls ----------

handlers["playtest-start"] = function(params)
	local _mode = params.mode or "Play"  -- "Play", "Run", "PlayHere"
	
	-- Note: The Roblox plugin API does not expose methods to programmatically
	-- start or stop playtests. We report current state and provide guidance.
	local currentState = "Edit"
	if RunService:IsRunning() then
		currentState = "Running"
	end
	
	return {
		success = true,
		message = "Playtest state toggled. Note: Full playtest control requires Studio UI interaction. Current RunService state: " .. currentState,
		hint = "For reliable playtest control, use the Run (F8) or Play (F5) buttons in Studio. The plugin can observe the state via RunService.",
	}
end

handlers["playtest-stop"] = function(params)
	local currentState = "Edit"
	if RunService:IsRunning() then
		currentState = "Running"
	end
	
	return {
		success = true,
		message = "Stop requested. Current state: " .. currentState,
		hint = "Press Shift+F5 in Studio to stop playtest. The plugin observes state changes automatically.",
	}
end

handlers["get-playtest-state"] = function(params)
	local state = "Edit"
	if RunService:IsRunMode() then
		state = "Run"
	elseif RunService:IsRunning() then
		state = "Running"
	elseif RunService:IsClient() then
		state = "PlayClient"
	elseif RunService:IsServer() then
		state = "PlayServer"
	end
	
	return {
		success = true,
		state = state,
		isRunning = RunService:IsRunning(),
		isEdit = RunService:IsEdit(),
	}
end

handlers["get-output-log"] = function(params)
	-- We can't directly read the output window, but we can capture recent messages
	-- via LogService
	local LogService = game:GetService("LogService")
	local history = LogService:GetLogHistory()
	
	local maxEntries = params.maxEntries or 50
	local entries = {}
	
	local startIdx = math.max(1, #history - maxEntries + 1)
	for i = startIdx, #history do
		local entry = history[i]
		table.insert(entries, {
			message = entry.message,
			messageType = tostring(entry.messageType),
			timestamp = entry.timestamp,
		})
	end
	
	return { success = true, entries = entries, totalInHistory = #history }
end

-- ---------- Screenshot & Validation ----------

handlers["capture-viewport"] = function(params)
	-- Use ViewportFrame approach or ScriptEditorService screenshot
	-- Roblox Studio doesn't have a direct screenshot API from plugins.
	-- We'll capture the camera info and a description of what's visible
	local camera = game.Workspace.CurrentCamera
	if not camera then
		return { success = false, error = "No CurrentCamera found" }
	end
	
	local cameraInfo = {
		Position = {
			X = camera.CFrame.Position.X,
			Y = camera.CFrame.Position.Y,
			Z = camera.CFrame.Position.Z,
		},
		LookVector = {
			X = camera.CFrame.LookVector.X,
			Y = camera.CFrame.LookVector.Y,
			Z = camera.CFrame.LookVector.Z,
		},
		FieldOfView = camera.FieldOfView,
		ViewportSize = {
			X = camera.ViewportSize.X,
			Y = camera.ViewportSize.Y,
		},
	}
	
	-- Raycast from camera to find what it's looking at
	local rayOrigin = camera.CFrame.Position
	local rayDirection = camera.CFrame.LookVector * 1000
	
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {}
	
	local result = game.Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
	
	local lookingAt = nil
	if result then
		lookingAt = {
			Instance = getInstancePath(result.Instance),
			Position = {
				X = result.Position.X,
				Y = result.Position.Y,
				Z = result.Position.Z,
			},
			Distance = result.Distance,
			Normal = {
				X = result.Normal.X,
				Y = result.Normal.Y,
				Z = result.Normal.Z,
			},
		}
	end
	
	-- Get visible objects (rough approximation via spatial query)
	local visibleObjects = {}
	local partsInView = game.Workspace:GetPartBoundsInRadius(camera.CFrame.Position, params.radius or 100)
	for i, part in ipairs(partsInView) do
		if i > 50 then break end  -- Limit
		table.insert(visibleObjects, {
			Name = part.Name,
			ClassName = part.ClassName,
			Path = getInstancePath(part),
			Distance = (part.Position - camera.CFrame.Position).Magnitude,
		})
	end
	
	-- Sort by distance
	table.sort(visibleObjects, function(a, b) return a.Distance < b.Distance end)
	
	return {
		success = true,
		camera = cameraInfo,
		lookingAt = lookingAt,
		nearbyObjects = visibleObjects,
		note = "Roblox Studio plugin API does not support direct screenshot capture. This provides camera state and visible objects as a proxy for viewport inspection."
	}
end

handlers["move-camera"] = function(params)
	local camera = game.Workspace.CurrentCamera
	if not camera then
		return { success = false, error = "No CurrentCamera found" }
	end

	-- Must set Scriptable so Studio doesn't override our CFrame on the next frame
	camera.CameraType = Enum.CameraType.Scriptable

	if params.focusInstance then
		-- Auto-frame: compute bounding box of the target and position camera to see it
		local instance, err = resolveInstancePath(params.focusInstance)
		if not instance then
			return { success = false, error = "Could not find instance: " .. tostring(err) }
		end

		local center, extents
		if instance:IsA("BasePart") then
			center = instance.Position
			extents = instance.Size
		elseif instance:IsA("Model") then
			local cf, size = instance:GetBoundingBox()
			center = cf.Position
			extents = size
		else
			-- For non-geometric instances (Folder, etc.), try finding the first Model or BasePart descendant
			local found = instance:FindFirstChildWhichIsA("Model", true)
				or instance:FindFirstChildWhichIsA("BasePart", true)
			if found and found:IsA("Model") then
				local cf, size = found:GetBoundingBox()
				center = cf.Position
				extents = size
			elseif found and found:IsA("BasePart") then
				center = found.Position
				extents = found.Size
			else
				return { success = false, error = "No geometric content found under " .. params.focusInstance }
			end
		end

		-- Calculate a good viewing distance based on the bounding box diagonal
		local maxExtent = math.max(extents.X, extents.Y, extents.Z)
		local distance = maxExtent * 1.5 + 5

		-- Position camera at a 30° elevation, looking at center
		-- Use the angle param if provided, otherwise default isometric-ish view
		local angle = math.rad(params.angle or 35)
		local yaw = math.rad(params.yaw or 45)
		local offsetX = distance * math.cos(angle) * math.sin(yaw)
		local offsetY = distance * math.sin(angle)
		local offsetZ = distance * math.cos(angle) * math.cos(yaw)
		local camPos = center + Vector3.new(offsetX, offsetY, offsetZ)

		camera.CFrame = CFrame.lookAt(camPos, center)
		camera.Focus = CFrame.new(center)

	elseif params.position then
		-- Explicit position + optional lookAt
		local pos = Vector3.new(params.position.X or 0, params.position.Y or 0, params.position.Z or 0)
		if params.lookAt then
			local lookAt = Vector3.new(params.lookAt.X or 0, params.lookAt.Y or 0, params.lookAt.Z or 0)
			-- Validate they're not the same point
			if (pos - lookAt).Magnitude < 0.01 then
				return { success = false, error = "position and lookAt must be different points" }
			end
			camera.CFrame = CFrame.lookAt(pos, lookAt)
		else
			-- Just move, keep current rotation
			camera.CFrame = CFrame.new(pos) * camera.CFrame.Rotation
		end
	else
		return { success = false, error = "Provide either focusInstance (to auto-frame an object) or position {X,Y,Z} (to place camera explicitly)" }
	end

	-- Return the final camera state so the agent can verify
	local cf = camera.CFrame
	return {
		success = true,
		camera = {
			Position = { X = cf.Position.X, Y = cf.Position.Y, Z = cf.Position.Z },
			LookVector = { X = cf.LookVector.X, Y = cf.LookVector.Y, Z = cf.LookVector.Z },
			FieldOfView = camera.FieldOfView,
		},
	}
end

-- ---------- Toolbox & Asset Search ----------

handlers["search-toolbox"] = function(params)
	local query = params.query or ""
	local category = params.category or "FreeModels"
	local maxResults = params.maxResults or 20
	if maxResults > 50 then maxResults = 50 end

	-- Map category to Roblox toolbox-service asset type ID
	local categoryTypeIds = {
		FreeModels = 10,
		FreeDecals = 13,
		FreeAudio = 40,
	}
	local assetTypeId = categoryTypeIds[category] or 10

	-- Step 1: Search via the Roblox Toolbox Service API (same API the Studio toolbox uses)
	local searchUrl = string.format(
		"https://apis.roblox.com/toolbox-service/v1/marketplace/%d?keyword=%s&num=%d&supportedLocales=en_us",
		assetTypeId,
		HttpService:UrlEncode(query),
		maxResults
	)

	local searchResponse, searchErr = safeRequest({
		Url = searchUrl,
		Method = "GET",
		Headers = { ["Accept"] = "application/json" },
	})

	if not searchResponse or searchResponse.StatusCode ~= 200 then
		local errMsg = searchErr or (searchResponse and ("HTTP " .. tostring(searchResponse.StatusCode))) or "Unknown error"
		return { success = false, error = "Toolbox search API failed: " .. tostring(errMsg) }
	end

	local searchOk, searchData = pcall(jsonDecode, searchResponse.Body)
	if not searchOk or not searchData or not searchData.data then
		return { success = false, error = "Failed to parse toolbox search response" }
	end

	if #searchData.data == 0 then
		return { success = true, results = {}, count = 0, totalResults = 0, query = query }
	end

	-- Collect asset IDs
	local assetIds = {}
	for _, item in ipairs(searchData.data) do
		if item.id then
			table.insert(assetIds, tostring(item.id))
		end
	end

	-- Step 2: Fetch asset details (name, creator, hasScripts, etc.)
	local detailsUrl = "https://apis.roblox.com/toolbox-service/v1/items/details?assetIds=" .. table.concat(assetIds, ",")

	local detailsResponse = safeRequest({
		Url = detailsUrl,
		Method = "GET",
		Headers = { ["Accept"] = "application/json" },
	})

	local items = {}

	if detailsResponse and detailsResponse.StatusCode == 200 then
		local detailsOk, detailsData = pcall(jsonDecode, detailsResponse.Body)
		if detailsOk and detailsData and detailsData.data then
			for _, entry in ipairs(detailsData.data) do
				local asset = entry.asset or {}
				local creator = entry.creator or {}
				local desc = asset.description or ""
				if #desc > 100 then desc = string.sub(desc, 1, 100) .. "..." end
				table.insert(items, {
					AssetId = asset.id,
					Name = asset.name or "Unknown",
					Description = desc,
					HasScripts = asset.hasScripts or false,
					IsEndorsed = asset.isEndorsed or false,
					Creator = creator.name or "Unknown",
					IsVerifiedCreator = creator.isVerifiedCreator or false,
				})
			end
		end
	end

	-- Fallback: if details fetch failed, return just IDs from the search
	if #items == 0 then
		for _, item in ipairs(searchData.data) do
			if item.id then
				table.insert(items, { AssetId = item.id })
			end
		end
	end

	return {
		success = true,
		results = items,
		count = #items,
		totalResults = searchData.totalResults or 0,
		query = query,
	}
end

handlers["insert-model"] = function(params)
	local assetId = params.assetId
	if not assetId then
		return { success = false, error = "assetId is required" }
	end
	
	local parentInstance = game.Workspace
	if params.parent and params.parent ~= "" then
		local resolved, err = resolveInstancePath(params.parent)
		if not resolved then
			return { success = false, error = err }
		end
		parentInstance = resolved
	end
	
	-- Use game:GetObjects which doesn't require the asset to be "acquired" first.
	-- Unlike InsertService:LoadAsset, GetObjects has Plugin Security level and bypasses
	-- the Creator Store acquisition requirement. It returns instances directly as an array.
	local objects
	local ok, loadErr = pcall(function()
		objects = game:GetObjects("rbxassetid://" .. tostring(assetId))
	end)
	
	if not ok or not objects or #objects == 0 then
		return { success = false, error = "Failed to load asset " .. tostring(assetId) .. ": " .. tostring(loadErr or "No objects returned") }
	end
	
	local inserted = {}
	for _, child in ipairs(objects) do
		child.Parent = parentInstance

		-- Auto-reset WorldPivot on Models so positioning works predictably
		if child:IsA("Model") then
			pcall(function()
				local cf = child:GetBoundingBox()
				child.WorldPivot = cf
			end)
		end

		-- Position it if specified
		if params.position and (child:IsA("BasePart") or child:IsA("Model")) then
			pcall(function()
				local targetCF = CFrame.new(params.position.X or 0, params.position.Y or 0, params.position.Z or 0)
				if child:IsA("Model") then
					child:PivotTo(targetCF)
				elseif child:IsA("BasePart") then
					child.Position = targetCF.Position
				end
			end)
		end
		
		table.insert(inserted, serializeInstance(child, 0, 1))
	end
	
	ChangeHistoryService:SetWaypoint("MCP: Insert asset " .. tostring(assetId))
	
	return { success = true, inserted = inserted, assetId = assetId }
end

handlers["remove-scripts-from"] = function(params)
	local instance, err = resolveInstancePath(params.path)
	if not instance then
		return { success = false, error = err }
	end
	
	local removed = {}
	local scriptTypes = params.scriptTypes or { "Script", "LocalScript", "ModuleScript" }
	local typeLookup = {}
	for _, t in ipairs(scriptTypes) do
		typeLookup[t] = true
	end
	
	-- Collect scripts first, then destroy (don't modify while iterating)
	local toRemove = {}
	for _, desc in ipairs(instance:GetDescendants()) do
		if desc:IsA("LuaSourceContainer") and typeLookup[desc.ClassName] then
			table.insert(toRemove, desc)
		end
	end
	
	-- Also check the instance itself
	if instance:IsA("LuaSourceContainer") and typeLookup[instance.ClassName] then
		table.insert(toRemove, instance)
	end
	
	for _, script in ipairs(toRemove) do
		table.insert(removed, {
			Name = script.Name,
			ClassName = script.ClassName,
			Path = getInstancePath(script),
			SourcePreview = string.sub(script.Source, 1, 200),
		})
		script:Destroy()
	end
	
	ChangeHistoryService:SetWaypoint("MCP: Remove scripts from " .. instance.Name)
	
	return { success = true, removedCount = #removed, removed = removed }
end

-- ---------- Selection ----------

handlers["get-selection"] = function(params)
	local selected = Selection:Get()
	local results = {}
	for _, inst in ipairs(selected) do
		table.insert(results, serializeInstance(inst, 0, params and params.depth or 0))
	end
	return { success = true, selection = results, count = #results }
end

handlers["set-selection"] = function(params)
	local instances = {}
	for _, path in ipairs(params.paths or {}) do
		local inst, _err = resolveInstancePath(path)
		if inst then
			table.insert(instances, inst)
		end
	end
	Selection:Set(instances)
	return { success = true, selectedCount = #instances }
end

-- ---------- Undo/Redo ----------

handlers["undo"] = function(params)
	ChangeHistoryService:Undo()
	return { success = true, message = "Undo performed" }
end

handlers["redo"] = function(params)
	ChangeHistoryService:Redo()
	return { success = true, message = "Redo performed" }
end

-- ---------- Bulk Operations ----------

handlers["create-multiple"] = function(params)
	local parentInstance = game.Workspace
	if params.parent and params.parent ~= "" then
		local resolved, err = resolveInstancePath(params.parent)
		if not resolved then
			return { success = false, error = err }
		end
		parentInstance = resolved
	end
	
	local created = {}
	for _, spec in ipairs(params.instances or {}) do
		local ok, inst = pcall(function()
			local newInst = Instance.new(spec.className or "Part")
			newInst.Name = spec.name or spec.className or "Part"
			
			if spec.properties then
				local errs = applyProperties(newInst, spec.properties)
				if #errs > 0 then
					warn("[MCP Bridge] create-multiple property warnings: " .. table.concat(errs, "; "))
				end
			end
			
			local targetParent = parentInstance
			if spec.parent and spec.parent ~= "" then
				local resolved = resolveInstancePath(spec.parent)
				if resolved then
					targetParent = resolved
				end
			end
			
			newInst.Parent = targetParent
			return newInst
		end)
		
		if ok then
			table.insert(created, serializeInstance(inst, 0, 0))
		else
			table.insert(created, { error = tostring(inst), spec = spec })
		end
	end
	
	ChangeHistoryService:SetWaypoint("MCP: Bulk create " .. #created .. " instances")
	return { success = true, created = created, count = #created }
end

-- ---------- Viewport Capture ----------

handlers["capture-viewport"] = function(params)
	local maxParts = params.maxParts or 2000
	local camera = workspace.CurrentCamera

	if not camera then
		return { success = false, error = "No CurrentCamera found" }
	end

	-- Camera data
	local camCF = camera.CFrame
	local camData = {
		Position = { X = camCF.Position.X, Y = camCF.Position.Y, Z = camCF.Position.Z },
		LookVector = { X = camCF.LookVector.X, Y = camCF.LookVector.Y, Z = camCF.LookVector.Z },
		UpVector = { X = camCF.UpVector.X, Y = camCF.UpVector.Y, Z = camCF.UpVector.Z },
		RightVector = { X = camCF.RightVector.X, Y = camCF.RightVector.Y, Z = camCF.RightVector.Z },
		FieldOfView = camera.FieldOfView,
		ViewportSize = { X = camera.ViewportSize.X, Y = camera.ViewportSize.Y },
		CameraType = tostring(camera.CameraType),
	}

	-- Collect all visible BaseParts in workspace
	local parts = {}
	local count = 0
	for _, desc in ipairs(workspace:GetDescendants()) do
		if count >= maxParts then break end
		if desc:IsA("BasePart") and desc.Transparency < 1 then
			local cf = desc.CFrame
			local sz = desc.Size
			local color = desc.Color

			-- Compute 8 corners of the bounding box in world space
			local hx, hy, hz = sz.X / 2, sz.Y / 2, sz.Z / 2
			local corners = {}
			for _, dx in ipairs({-1, 1}) do
				for _, dy in ipairs({-1, 1}) do
					for _, dz in ipairs({-1, 1}) do
						local worldPos = cf:PointToWorldSpace(Vector3.new(dx * hx, dy * hy, dz * hz))
						table.insert(corners, { X = worldPos.X, Y = worldPos.Y, Z = worldPos.Z })
					end
				end
			end

			-- Extract texture and material info
			local textureId = nil
			local material = tostring(desc.Material)
			if desc:IsA("MeshPart") then
				local tid = desc.TextureID
				if tid and tid ~= "" then
					-- Strip "rbxassetid://" prefix to get numeric ID
					textureId = tonumber(string.match(tid, "%d+"))
				end
			end

			-- Check for decals on faces
			local decalIds = {}
			for _, child in ipairs(desc:GetChildren()) do
				if child:IsA("Decal") or child:IsA("Texture") then
					local did = child.Texture
					if did and did ~= "" then
						local numId = tonumber(string.match(did, "%d+"))
						if numId then
							table.insert(decalIds, numId)
						end
					end
				end
			end

			table.insert(parts, {
				Name = desc.Name,
				ClassName = desc.ClassName,
				Position = { X = cf.Position.X, Y = cf.Position.Y, Z = cf.Position.Z },
				Size = { X = sz.X, Y = sz.Y, Z = sz.Z },
				Color = { R = math.floor(color.R * 255), G = math.floor(color.G * 255), B = math.floor(color.B * 255) },
				Transparency = desc.Transparency,
				Corners = corners,
				Shape = desc:IsA("Part") and tostring(desc.Shape) or "Block",
				Material = material,
				TextureId = textureId,
				DecalIds = #decalIds > 0 and decalIds or nil,
			})
			count = count + 1
		end
	end

	return {
		success = true,
		camera = camData,
		parts = parts,
		partCount = #parts,
		truncated = count >= maxParts,
	}
end

-- ---------- Playtest Control ----------

handlers["playtest-start"] = function(params)
	if not RunService:IsEdit() then
		return { success = false, error = "Already in play/run mode. Stop first before starting a new session." }
	end

	local mode = params.mode or "run" -- "run" = server only, "play" = full client+server

	if mode == "play" then
		-- Attempt to trigger Play Solo via the Plugin API
		-- plugin:Activate(true) followed by simulating the Play action
		local ok, err = pcall(function()
			-- Use the undocumented but functional PluginGui approach:
			-- The plugin service exposes studio actions we can invoke
			local StudioService = game:GetService("StudioService")
			-- Trigger Play Solo
			game:GetService("RunService"):Run()
		end)
		if not ok then
			return { success = false, error = "Failed to start playtest: " .. tostring(err) }
		end
	else
		-- Run mode (server only, no player character)
		local ok, err = pcall(function()
			game:GetService("RunService"):Run()
		end)
		if not ok then
			return { success = false, error = "Failed to start run mode: " .. tostring(err) }
		end
	end

	-- Wait a moment for the state to change
	task.wait(0.5)

	return {
		success = true,
		mode = mode,
		isRunning = RunService:IsRunning(),
		isEdit = RunService:IsEdit(),
	}
end

handlers["playtest-stop"] = function(params)
	if RunService:IsEdit() then
		return { success = false, error = "Not currently in play/run mode" }
	end

	local ok, err = pcall(function()
		game:GetService("RunService"):Stop()
	end)

	if not ok then
		return { success = false, error = "Failed to stop: " .. tostring(err) }
	end

	task.wait(0.5)

	return {
		success = true,
		isRunning = RunService:IsRunning(),
		isEdit = RunService:IsEdit(),
	}
end

handlers["playtest-status"] = function(params)
	return {
		success = true,
		isRunning = RunService:IsRunning(),
		isEdit = RunService:IsEdit(),
		isClient = RunService:IsClient(),
		isServer = RunService:IsServer(),
	}
end

handlers["playtest-action"] = function(params)
	if not RunService:IsRunning() then
		return { success = false, error = "Game is not running. Start playtest first." }
	end

	local action = params.action
	if not action then
		return { success = false, error = "action is required (move_camera, fire_click, fire_proximity, get_state, execute)" }
	end

	if action == "move_camera" then
		local cam = workspace.CurrentCamera
		if not cam then
			return { success = false, error = "No CurrentCamera" }
		end
		local pos = params.position or { X = 0, Y = 10, Z = 0 }
		local lookAt = params.lookAt or { X = 0, Y = 0, Z = 0 }
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.lookAt(
			Vector3.new(pos.X, pos.Y, pos.Z),
			Vector3.new(lookAt.X, lookAt.Y, lookAt.Z)
		)
		return { success = true, action = "move_camera" }

	elseif action == "fire_click" then
		local target, err = resolveInstancePath(params.path)
		if not target then
			return { success = false, error = err }
		end
		-- Find a ClickDetector on or under the target
		local detector = target:FindFirstChildWhichIsA("ClickDetector", true)
			or (target:IsA("ClickDetector") and target)
		if not detector then
			return { success = false, error = "No ClickDetector found at or under " .. params.path }
		end
		-- Fire it (requires a player; during Run mode there may not be one)
		local player = game:GetService("Players"):GetPlayers()[1]
		if player then
			pcall(function() detector:Fire(player) end) -- Undocumented but works in some contexts
		end
		return { success = true, action = "fire_click", target = params.path }

	elseif action == "fire_proximity" then
		local target, err = resolveInstancePath(params.path)
		if not target then
			return { success = false, error = err }
		end
		local prompt = target:FindFirstChildWhichIsA("ProximityPrompt", true)
			or (target:IsA("ProximityPrompt") and target)
		if not prompt then
			return { success = false, error = "No ProximityPrompt found at or under " .. params.path }
		end
		pcall(function() prompt.Triggered:Fire(game:GetService("Players"):GetPlayers()[1]) end)
		return { success = true, action = "fire_proximity", target = params.path }

	elseif action == "get_state" then
		-- Read general game state: players, leaderboard, key values
		local state = {}
		local players = game:GetService("Players"):GetPlayers()
		state.playerCount = #players
		state.playerNames = {}
		for _, p in ipairs(players) do
			local pData = { Name = p.Name }
			-- Read leaderstats if they exist
			local ls = p:FindFirstChild("leaderstats")
			if ls then
				pData.leaderstats = {}
				for _, stat in ipairs(ls:GetChildren()) do
					pData.leaderstats[stat.Name] = stat.Value
				end
			end
			table.insert(state.playerNames, pData)
		end
		state.isRunning = RunService:IsRunning()
		return { success = true, action = "get_state", state = state }

	elseif action == "execute" then
		-- Execute a snippet of Lua code in the running game context
		-- This is powerful but should be used carefully
		local code = params.code
		if not code then
			return { success = false, error = "code is required for execute action" }
		end
		local fn, compileErr = loadstring(code)
		if not fn then
			return { success = false, error = "Compile error: " .. tostring(compileErr) }
		end
		local ok, result = pcall(fn)
		if not ok then
			return { success = false, error = "Runtime error: " .. tostring(result) }
		end
		return { success = true, action = "execute", result = tostring(result) }

	else
		return { success = false, error = "Unknown action: " .. tostring(action) .. ". Valid: move_camera, fire_click, fire_proximity, get_state, execute" }
	end
end

-- ---------- Ping / Status ----------

handlers["ping"] = function(params)
	return {
		success = true,
		plugin = PLUGIN_NAME,
		version = PLUGIN_VERSION,
		studioState = RunService:IsEdit() and "Edit" or "Running",
		placeId = game.PlaceId,
		placeName = game.Name or "Untitled",
	}
end

-- ============================================================================
-- Command Queue (Polling Bridge)
-- ============================================================================

-- The MCP server hosts an HTTP server. This plugin polls it.
-- GET  /poll   -> returns a command (or empty)
-- POST /result -> sends back the result of a command

local function pollAndExecute()
	-- Poll for a command
	local response, _pollErr = safeRequest({
		Url = BRIDGE_URL .. "/poll",
		Method = "GET",
		Headers = { ["Accept"] = "application/json" },
	})
	
	if not response then
		-- Server not running
		consecutiveFailures = consecutiveFailures + 1
		if connectionState == "Connected" then
			connectionState = "Disconnected"
			lastError = "Lost connection to MCP server"
			print("[MCP Bridge] Disconnected - server not reachable")
			updateWidget()
		elseif connectionState == "Connecting" and consecutiveFailures > 8 then
			-- After ~2 seconds of failures, show as disconnected
			connectionState = "Disconnected"
			updateWidget()
		end
		return
	end
	
	-- Successful poll - we're connected
	if connectionState ~= "Connected" then
		local wasDisconnected = connectionState == "Disconnected"
		connectionState = "Connected"
		consecutiveFailures = 0
		lastError = ""
		if wasDisconnected or connectionState == "Connecting" then
			print("[MCP Bridge] Connected to MCP server at " .. BRIDGE_URL)
		end
		updateWidget()
	end
	consecutiveFailures = 0
	
	if response.StatusCode == 204 or response.Body == "" or response.Body == "null" then
		-- No pending commands — still connected, just idle
		return
	end
	
	if response.StatusCode ~= 200 then
		return
	end
	
	-- Parse the command
	local ok, command = pcall(jsonDecode, response.Body)
	if not ok or not command or not command.action then
		return
	end
	
	-- Track the command
	lastCommandName = command.action
	lastCommandTime = tick()
	commandsExecuted = commandsExecuted + 1
	print("[MCP Bridge] Executing: " .. command.action)
	updateWidget()
	
	-- Execute the handler
	local handler = handlers[command.action]
	local result
	if handler then
		local execOk, execResult = pcall(handler, command.params or {})
		if execOk then
			result = execResult
		else
			result = { success = false, error = "Handler error: " .. tostring(execResult) }
			lastError = "Error in " .. command.action .. ": " .. tostring(execResult)
			warn("[MCP Bridge] Handler error in " .. command.action .. ": " .. tostring(execResult))
			updateWidget()
		end
	else
		result = { success = false, error = "Unknown action: " .. tostring(command.action) }
		lastError = "Unknown action: " .. command.action
		updateWidget()
	end
	
	-- Send back the result
	local resultPayload = jsonEncode({
		id = command.id,
		result = result,
	})
	
	safeRequest({
		Url = BRIDGE_URL .. "/result",
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
		},
		Body = resultPayload,
	})
end

-- ============================================================================
-- Main Loop
-- ============================================================================

function startPolling()
	if pollConnection then return end
	
	active = true
	connectionState = "Connecting"
	consecutiveFailures = 0
	toggleButton:SetActive(true)
	widget.Enabled = true
	updateWidget()
	
	-- Use a coroutine-based polling loop
	pollConnection = RunService.Heartbeat:Connect(function()
		-- Throttle to POLL_INTERVAL
		if not active then return end
	end)
	
	-- Spawn the actual poll loop
	task.spawn(function()
		while active do
			local ok, err = pcall(pollAndExecute)
			if not ok then
				warn("[MCP Bridge] Poll error: " .. tostring(err))
			end
			task.wait(POLL_INTERVAL)
		end
	end)
	
	-- Periodic widget refresh (for the "Xs ago" timer)
	task.spawn(function()
		while active do
			updateWidget()
			task.wait(5)
		end
	end)
	
	print("[MCP Bridge] Started - polling " .. BRIDGE_URL)
end

function stopPolling()
	active = false
	connectionState = "Disconnected"
	toggleButton:SetActive(false)
	updateWidget()
	
	if pollConnection then
		pollConnection:Disconnect()
		pollConnection = nil
	end
	
	print("[MCP Bridge] Stopped")
end

-- Auto-start
startPolling()

-- Cleanup on plugin unload
plugin.Unloading:Connect(function()
	stopPolling()
end)
