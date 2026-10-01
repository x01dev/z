--[[
================================================================================
 NebulaUI — layered, nebula-themed UI library for Roblox
================================================================================

 INSTALL
   Put this in a LocalScript under StarterPlayer > StarterPlayerScripts,
   or host it and load it as a library (it ends with `return Nebula`).

 FILE MAP  (search for the "[n]" tags to jump around)
   [1] Services
   [2] Theme & Config ............ colors, sizes, defaults — edit these first
   [3] Utilities ................. small helpers shared by everything + createPlanet
   [4] Library
       [4.1] Window shell ........ backdrop layers, header, sidebar, page area
       [4.2] Window state ........ dragging, toggle key, cleanup, notifications,
                                   flag registry (what the config system saves)
       [4.3] Window:AddTab ....... returns a Tab with all the element builders
             Tab:AddConfigManager  the config box + Save / Load / Delete
       [4.4] Window:AddSettingsTab / Window:AddConfigTab
   [5] Example usage

 API QUICK REFERENCE
   local Window = Nebula.CreateWindow({Title, Subtitle, Size, ToggleKey})
   Window:AddTab(name, icon)            -> Tab
   Window:AddSettingsTab(name)          -> Tab   (menu keybind + unload button)
   Window:AddConfigTab(name, {Folder})  -> Tab   (config list + save/load/delete)
   Window:Toggle()  Window:Destroy()
   Window:SetToggleKey(KeyCode)  Window:GetToggleKey()
   Window:Notify(title, text, seconds)
   Window.Flags[flag]                   -> the element object, e.g. Window.Flags.Speed:Get()

   Tab:AddSection(text)
   Tab:AddLabel(text)                   -> {Set}
   Tab:AddButton({Name, Callback})
   Tab:AddToggle({Name, Default, Flag, Callback(bool)})              -> {Get, Set}
   Tab:AddSlider({Name, Min, Max, Step, Default, Suffix, Flag, Callback(number)})
                                                                     -> {Get, Set}
   Tab:AddDropdown({Name, Options, Default, Flag, Callback(string)})  -> {Get, Set}
   Tab:AddMultiDropdown({Name, Options, Default, Flag, Callback(table)}) -> {Get, Set}
   Tab:AddColorPicker({Name, Default, Flag, Callback(Color3)})       -> {Get, Set}
   Tab:AddKeybind({Name, Default, Flag, Callback(KeyCode)})          -> {Get, Set}
   Tab:AddConfigManager({Folder})       -> {Refresh}

 CONFIG SYSTEM
   Give any element a unique `Flag = "SomeName"` and it is saved/loaded
   automatically. Elements without a Flag are ignored. Configs are stored as
   JSON files in the executor workspace (default folder: NebulaUI/Configs).
   If the environment has no file functions (writefile etc.), configs fall back
   to in-memory storage and last until you leave the game.

 HOW THE BACKGROUND IS LAYERED (back to front)
   Backdrop (CanvasGroup, rounded — clips everything inside to the curve)
     Layer 1  base gradient
     Layer 2  little drifting planets (rim light, bands/craters, fading rings)
     Layer 3  twinkling stars
   Layer 4  interface (header, sidebar, pages) — normal Frames on top
   Border   animated gradient UIStroke around the whole window

 NOTE: ClipsDescendants only clips to a *rectangle* and ignores UICorner. That
 is why the backdrop is a CanvasGroup — it is the one container that clips its
 children to rounded corners.
================================================================================
]]

------------------------------------------------------------------------------
-- [1] SERVICES
------------------------------------------------------------------------------
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local Nebula = {}

------------------------------------------------------------------------------
-- [2] THEME & CONFIG
------------------------------------------------------------------------------
local Theme = {
	Background   = Color3.fromRGB(10, 8, 22),
	Panel        = Color3.fromRGB(18, 14, 40),
	Element      = Color3.fromRGB(28, 22, 58),
	ElementHover = Color3.fromRGB(42, 33, 86),
	Input        = Color3.fromRGB(14, 10, 34),
	Accent       = Color3.fromRGB(150, 90, 255),
	Accent2      = Color3.fromRGB(70, 170, 255),
	Pink         = Color3.fromRGB(255, 100, 200),
	Danger       = Color3.fromRGB(255, 90, 120),
	Text         = Color3.fromRGB(240, 235, 255),
	SubText      = Color3.fromRGB(165, 155, 205),
	Stroke       = Color3.fromRGB(95, 75, 180),
}
Nebula.Theme = Theme

local Config = {
	WindowSize       = Vector2.new(580, 400),
	WindowRadius     = 12,
	HeaderHeight     = 42,
	SidebarWidth     = 140,
	DefaultToggleKey = Enum.KeyCode.RightShift,
	StarCount        = 55,
	ConfigFolder     = "NebulaUI/Configs",
}

------------------------------------------------------------------------------
-- [3] UTILITIES
------------------------------------------------------------------------------

-- Creates an Instance, applies props, parents LAST (faster, avoids reflows).
local function create(class, props, children)
	local inst = Instance.new(class)
	local parent
	for key, value in pairs(props or {}) do
		if key == "Parent" then parent = value else inst[key] = value end
	end
	for _, child in ipairs(children or {}) do child.Parent = inst end
	inst.Parent = parent
	return inst
end

local function tween(obj, props, time, style, direction)
	local t = TweenService:Create(
		obj,
		TweenInfo.new(time or 0.2, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out),
		props
	)
	t:Play()
	return t
end

-- Endlessly ping-pongs a property (used for planets / stars).
local function loopTween(obj, props, time, delay)
	local info = TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, delay or 0)
	TweenService:Create(obj, info, props):Play()
end

local function corner(parent, radius)
	return create("UICorner", {CornerRadius = UDim.new(0, radius or 8), Parent = parent})
end

local function stroke(parent, color, transparency, thickness)
	return create("UIStroke", {
		Color = color or Theme.Stroke,
		Transparency = transparency or 0.5,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

local function gradient(parent, c0, c1, rotation)
	return create("UIGradient", {Color = ColorSequence.new(c0, c1), Rotation = rotation or 0, Parent = parent})
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function isMove(input)
	return input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch
end

-- Runs a callback on its own thread so an error in user code can't break the UI.
local function fire(callback, ...)
	if callback then task.spawn(callback, ...) end
end

-- Rounds `value` to the nearest multiple of `step` (and fixes float noise).
local function roundTo(value, step)
	return tonumber(string.format("%.4f", math.floor(value / step + 0.5) * step))
end

-- Do we have executor-style file access? (If not, configs live in memory only.)
local HAS_FS = type(writefile) == "function"
	and type(readfile) == "function"
	and type(isfolder) == "function"
	and type(makefolder) == "function"
	and type(listfiles) == "function"
	and type(delfile) == "function"

-- Strips anything unsafe for a file name; trims and caps the length.
local function sanitizeName(text)
	local name = tostring(text or "")
	name = string.gsub(name, "[^%w%s%-_]", "")
	name = string.gsub(name, "^%s+", "")
	name = string.gsub(name, "%s+$", "")
	return string.sub(name, 1, 32)
end

local HUE_COLORS = ColorSequence.new({
	ColorSequenceKeypoint.new(0 / 6, Color3.fromRGB(255, 0, 0)),
	ColorSequenceKeypoint.new(1 / 6, Color3.fromRGB(255, 255, 0)),
	ColorSequenceKeypoint.new(2 / 6, Color3.fromRGB(0, 255, 0)),
	ColorSequenceKeypoint.new(3 / 6, Color3.fromRGB(0, 255, 255)),
	ColorSequenceKeypoint.new(4 / 6, Color3.fromRGB(0, 0, 255)),
	ColorSequenceKeypoint.new(5 / 6, Color3.fromRGB(255, 0, 255)),
	ColorSequenceKeypoint.new(6 / 6, Color3.fromRGB(255, 0, 0)),
})

-- Builds one little planet and starts it drifting. `def` fields:
--   name, diameter, x, y ......... identity and placement (pixels)
--   light, dark .................. lit-side and shadow-side colors of the sphere
--   band, bands = {{y, h}} ....... optional gas-giant stripes (fractions of diameter)
--   craters = {{x, y, size}} ..... optional craters (fractions of diameter)
--   ring, tilt ................... optional ring color and tilt in degrees (fades at the tips/shadow side)
--   drift (Vector2), time ........ how far and how slowly it floats back and forth
-- The sphere is a CanvasGroup so bands/craters/shading are clipped to a true circle.
local function createPlanet(parent, def)
	local d = def.diameter
	local holder = create("Frame", {
		Name = def.name, Size = UDim2.fromOffset(d, d), Position = UDim2.fromOffset(def.x, def.y),
		BackgroundTransparency = 1, Parent = parent,
	})

	-- sphere (ZIndex 3)
	local sphere = create("CanvasGroup", {
		Name = "Sphere", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
		BorderSizePixel = 0, ZIndex = 3, Parent = holder,
	})
	corner(sphere, d)

	local surface = create("Frame", {
		Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = sphere,
	})
	gradient(surface, def.light, def.dark, 45)

	for _, band in ipairs(def.bands or {}) do
		create("Frame", {
			Position = UDim2.fromScale(0, band.y), Size = UDim2.fromScale(1, band.h),
			BackgroundColor3 = def.band or def.light, BackgroundTransparency = 0.6, BorderSizePixel = 0, Parent = sphere,
		})
	end
	for _, crater in ipairs(def.craters or {}) do
		local dent = create("Frame", {
			Position = UDim2.fromScale(crater.x, crater.y), Size = UDim2.fromScale(crater.size, crater.size),
			BackgroundColor3 = def.dark, BackgroundTransparency = 0.5, BorderSizePixel = 0, Parent = sphere,
		})
		corner(dent, d)
	end

	-- night-side shading (light comes from the top-left)
	local shade = create("Frame", {
		Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, Parent = sphere,
	})
	create("UIGradient", {
		Rotation = 45,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.45, 0.85),
			NumberSequenceKeypoint.new(1, 0.15),
		}),
		Parent = shade,
	})

	-- thin rim light on the lit (top-left) edge only; fades out toward the shadow side
	local rim = create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 4, Parent = holder})
	corner(rim, d)
	local rimStroke = stroke(rim, def.light, 0, 1.5)
	create("UIGradient", {
		Rotation = 45,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.5, 0.85),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = rimStroke,
	})

	-- optional ring: two fine tracks of dots. The far half sits behind the sphere
	-- (ZIndex 2) and the near half in front (ZIndex 4). Each dot is shaded by how much
	-- light it receives (same top-left light as the sphere) and fades out toward the
	-- ring tips and the shadow side, so it blends into the planet instead of reading
	-- as a flat outline.
	if def.ring then
		local tiltRad = math.rad(def.tilt or -18)
		local function ringLayer(zIndex)
			return create("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(0, 0),
				Rotation = def.tilt or -18, BackgroundTransparency = 1, ZIndex = zIndex, Parent = holder,
			})
		end
		local back, front = ringLayer(2), ringLayer(4)

		local tracks = {1.0, 0.86} -- outer and inner track (relative radius)
		local count = 120          -- dots per track
		for _, trackScale in ipairs(tracks) do
			local rx, ry = d * 1.15 * trackScale, d * 0.30 * trackScale
			for i = 0, count - 1 do
				local angle = (i / count) * math.pi * 2
				local px, py = math.cos(angle) * rx, math.sin(angle) * ry
				local isFront = math.sin(angle) > 0

				-- where the dot ends up on screen after the tilt (used for lighting)
				local wx = px * math.cos(tiltRad) - py * math.sin(tiltRad)
				local wy = px * math.sin(tiltRad) + py * math.cos(tiltRad)
				local lit = math.clamp((-wx - wy) / (rx * 1.41), -1, 1) * 0.5 + 0.5 -- 0 = shadow, 1 = lit
				local tipFade = math.abs(math.cos(angle)) ^ 3                       -- 0 mid-ring, 1 at the tips

				local transparency = (isFront and 0.2 or 0.55) + tipFade * 0.35 + (1 - lit) * 0.2
				create("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(px, py), Size = UDim2.fromOffset(2, 2),
					BackgroundColor3 = def.dark:Lerp(def.ring, 0.4 + lit * 0.6),
					BackgroundTransparency = math.min(transparency, 0.95),
					BorderSizePixel = 0, Parent = isFront and front or back,
				})
			end
		end
	end

	loopTween(holder, {Position = UDim2.fromOffset(def.x + def.drift.X, def.y + def.drift.Y)}, def.time)
	return holder
end

------------------------------------------------------------------------------
-- [4] LIBRARY
------------------------------------------------------------------------------
function Nebula.CreateWindow(opts)
	opts = opts or {}
	local title = opts.Title or "Nebula"
	local subtitle = opts.Subtitle or "UI Library"
	local size = opts.Size or Config.WindowSize

	local Window = {}

	--------------------------------------------------------------------------
	-- [4.2] WINDOW STATE (declared first because everything below uses it)
	--------------------------------------------------------------------------
	local connections = {}       -- every global (UserInputService) connection, for cleanup
	local activeDrag = nil       -- function(pos) while the mouse is held on a draggable thing
	local listeningForKey = false-- true while a Keybind element is waiting for a key press
	local toggleKey = opts.ToggleKey or Config.DefaultToggleKey
	local minimized = false

	-- Flag registry: every element created with a `Flag` ends up here. The config
	-- system walks this table to save and load. Window.Flags exposes the objects
	-- so you can also read values from your own code (Window.Flags.Speed:Get()).
	local registry = {}          -- flag -> {kind, object, options}
	Window.Flags = {}

	local function register(o, kind, object)
		if o and o.Flag then
			registry[o.Flag] = {kind = kind, object = object, options = o.Options}
			Window.Flags[o.Flag] = object
		end
	end

	local function connect(signal, handler)
		local connection = signal:Connect(handler)
		table.insert(connections, connection)
		return connection
	end

	-- One shared drag system: any element calls bindDrag(hitbox, fn).
	local function bindDrag(object, fn)
		object.InputBegan:Connect(function(input)
			if isPress(input) then
				activeDrag = fn
				fn(input.Position)
			end
		end)
	end
	connect(UIS.InputChanged, function(input)
		if activeDrag and isMove(input) then activeDrag(input.Position) end
	end)
	connect(UIS.InputEnded, function(input)
		if isPress(input) then activeDrag = nil end
	end)

	--------------------------------------------------------------------------
	-- [4.1] WINDOW SHELL
	--------------------------------------------------------------------------
	local gui = create("ScreenGui", {
		Name = "NebulaUI",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})

	-- Main is transparent: it only positions the window and draws the border.
	local main = create("Frame", {
		Name = "Main",
		Size = UDim2.fromOffset(size.X, size.Y),
		Position = UDim2.new(0.5, -size.X / 2, 0.5, -size.Y / 2),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = gui,
	})
	corner(main, Config.WindowRadius)

	local border = create("UIStroke", {
		Thickness = 1.5, Transparency = 0.15,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = main,
	})
	local borderGradient = create("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Accent),
			ColorSequenceKeypoint.new(0.5, Theme.Accent2),
			ColorSequenceKeypoint.new(1, Theme.Pink),
		}),
		Parent = border,
	})
	TweenService:Create(borderGradient,
		TweenInfo.new(6, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1),
		{Rotation = 360}):Play()

	-- BACKDROP: CanvasGroup + UICorner = children are clipped to the rounded shape.
	local backdrop = create("CanvasGroup", {
		Name = "Backdrop",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Background,
		BorderSizePixel = 0,
		Parent = main,
	})
	corner(backdrop, Config.WindowRadius)

	-- Layer 1: base gradient
	local base = create("Frame", {
		Name = "Layer1_Base", Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = backdrop,
	})
	create("UIGradient", {
		Rotation = 45,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(14, 8, 36)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(26, 12, 58)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(8, 16, 44)),
		}),
		Parent = base,
	})

	-- Layer 2: little drifting planets (fields are documented above createPlanet)
	local planetLayer = create("Frame", {Name = "Layer2_Planets", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = backdrop})
	local planetDefs = {
		{ -- violet ringed gas giant, top right
			name = "GasGiant", diameter = 76, x = size.X - 160, y = 48,
			light = Color3.fromRGB(200, 150, 255), dark = Color3.fromRGB(70, 30, 150),
			band = Color3.fromRGB(245, 215, 255), bands = {{y = 0.28, h = 0.07}, {y = 0.44, h = 0.10}, {y = 0.65, h = 0.06}},
			ring = Color3.fromRGB(220, 190, 255), tilt = -18, drift = Vector2.new(-14, 10), time = 9,
		},
		{ -- small ice world, bottom middle
			name = "IceWorld", diameter = 44, x = size.X * 0.5, y = size.Y - 88,
			light = Color3.fromRGB(160, 235, 255), dark = Color3.fromRGB(30, 90, 170),
			craters = {{x = 0.55, y = 0.25, size = 0.18}},
			drift = Vector2.new(18, -8), time = 7,
		},
		{ -- ember world with craters, bottom left
			name = "EmberWorld", diameter = 58, x = 26, y = size.Y - 180,
			light = Color3.fromRGB(255, 175, 205), dark = Color3.fromRGB(150, 40, 110),
			craters = {{x = 0.20, y = 0.30, size = 0.20}, {x = 0.55, y = 0.55, size = 0.14}, {x = 0.40, y = 0.12, size = 0.10}},
			drift = Vector2.new(12, 12), time = 11,
		},
		{ -- tiny moon, bottom right
			name = "Moon", diameter = 24, x = size.X - 72, y = size.Y - 92,
			light = Color3.fromRGB(235, 235, 255), dark = Color3.fromRGB(100, 100, 150),
			craters = {{x = 0.30, y = 0.30, size = 0.25}},
			drift = Vector2.new(-10, -6), time = 6,
		},
	}
	for _, def in ipairs(planetDefs) do
		createPlanet(planetLayer, def)
	end

	-- Layer 3: twinkling stars (fixed seed = same sky every time)
	local stars = create("Frame", {Name = "Layer3_Stars", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = backdrop})
	local rng = Random.new(42)
	for _ = 1, Config.StarCount do
		local px = rng:NextInteger(1, 2)
		local star = create("Frame", {
			Size = UDim2.fromOffset(px, px),
			Position = UDim2.fromScale(rng:NextNumber(), rng:NextNumber()),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = rng:NextNumber(0.3, 0.8),
			BorderSizePixel = 0, Parent = stars,
		})
		corner(star, 2)
		loopTween(star, {BackgroundTransparency = 1}, rng:NextNumber(1, 3.5), rng:NextNumber(0, 2))
	end

	-- Layer 4: interface
	local ui = create("Frame", {Name = "Layer4_UI", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = main})

	-- Header ---------------------------------------------------------------
	local header = create("Frame", {
		Name = "Header", Size = UDim2.new(1, 0, 0, Config.HeaderHeight), BackgroundTransparency = 1, Parent = ui,
	})

	local titleRow = create("Frame", {
		Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -120, 1, 0), BackgroundTransparency = 1, Parent = header,
	})
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = titleRow,
	})
	local titleLabel = create("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.fromOffset(0, Config.HeaderHeight), AutomaticSize = Enum.AutomaticSize.X,
		Font = Enum.Font.GothamBold, Text = "✦ " .. title, TextSize = 17, TextColor3 = Color3.new(1, 1, 1), Parent = titleRow,
	})
	gradient(titleLabel, Theme.Accent2, Theme.Pink, 0)
	create("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.fromOffset(0, Config.HeaderHeight), AutomaticSize = Enum.AutomaticSize.X,
		Font = Enum.Font.Gotham, Text = subtitle, TextSize = 12, TextColor3 = Theme.SubText, Parent = titleRow,
	})

	local headerLine = create("Frame", {
		Position = UDim2.new(0, 12, 1, -1), Size = UDim2.new(1, -24, 0, 1),
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = header,
	})
	create("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Accent),
			ColorSequenceKeypoint.new(0.5, Theme.Accent2),
			ColorSequenceKeypoint.new(1, Theme.Pink),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.2), NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = headerLine,
	})

	local function headerButton(text, xOffset)
		local button = create("TextButton", {
			Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, xOffset, 0, 8),
			BackgroundColor3 = Theme.Element, BackgroundTransparency = 0.3,
			Text = text, Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Theme.Text,
			AutoButtonColor = false, Parent = header,
		})
		corner(button, 7)
		button.MouseEnter:Connect(function() tween(button, {BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.1}, 0.15) end)
		button.MouseLeave:Connect(function() tween(button, {BackgroundColor3 = Theme.Element, BackgroundTransparency = 0.3}, 0.15) end)
		return button
	end
	local closeButton = headerButton("×", -36)
	local minimizeButton = headerButton("–", -68)

	-- Body: sidebar (tab buttons) + pages ------------------------------------
	local body = create("Frame", {
		Name = "Body", Position = UDim2.fromOffset(0, Config.HeaderHeight + 2),
		Size = UDim2.new(1, 0, 1, -(Config.HeaderHeight + 2)), BackgroundTransparency = 1, Parent = ui,
	})

	local sidebar = create("Frame", {
		Name = "Sidebar", Position = UDim2.fromOffset(10, 4), Size = UDim2.new(0, Config.SidebarWidth, 1, -14),
		BackgroundColor3 = Theme.Panel, BackgroundTransparency = 0.3, BorderSizePixel = 0, Parent = body,
	})
	corner(sidebar, 10)
	stroke(sidebar, Theme.Stroke, 0.65)

	local tabList = create("Frame", {
		Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -12), BackgroundTransparency = 1, Parent = sidebar,
	})
	create("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = tabList})

	local pages = create("Frame", {
		Name = "Pages", Position = UDim2.fromOffset(Config.SidebarWidth + 20, 4),
		Size = UDim2.new(1, -(Config.SidebarWidth + 30), 1, -14), BackgroundTransparency = 1, Parent = body,
	})

	--------------------------------------------------------------------------
	-- [4.2] WINDOW BEHAVIOUR: drag, minimize, toggle key, notifications
	--------------------------------------------------------------------------

	-- Drag by the header.
	header.InputBegan:Connect(function(input)
		if not isPress(input) then return end
		local startMouse, startPos = input.Position, main.Position
		activeDrag = function(pos)
			local delta = pos - startMouse
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)

	minimizeButton.MouseButton1Click:Connect(function()
		minimized = not minimized
		body.Visible = not minimized
		tween(main, {Size = UDim2.fromOffset(size.X, minimized and Config.HeaderHeight or size.Y)}, 0.25)
	end)
	closeButton.MouseButton1Click:Connect(function() Window:Destroy() end)

	-- Menu open/close key. Ignored while typing in a TextBox (processed) or
	-- while a Keybind element is waiting for input (listeningForKey).
	connect(UIS.InputBegan, function(input, processed)
		if processed or listeningForKey then return end
		if input.KeyCode == toggleKey then Window:Toggle() end
	end)

	function Window:Toggle() main.Visible = not main.Visible end
	function Window:SetToggleKey(keyCode) toggleKey = keyCode end
	function Window:GetToggleKey() return toggleKey end

	function Window:Destroy()
		for _, connection in ipairs(connections) do connection:Disconnect() end
		table.clear(connections)
		activeDrag = nil
		gui:Destroy()
	end

	-- Notifications stack in the bottom-right corner.
	local notifyHolder = create("Frame", {
		Name = "Notifications", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16), Size = UDim2.fromOffset(260, 400), Parent = gui,
	})
	create("UIListLayout", {
		VerticalAlignment = Enum.VerticalAlignment.Bottom, HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = notifyHolder,
	})

	function Window:Notify(heading, text, duration)
		local card = create("Frame", {
			Size = UDim2.fromOffset(260, 58), BackgroundColor3 = Theme.Panel, BackgroundTransparency = 1, Parent = notifyHolder,
		})
		corner(card, 10)
		local cardStroke = stroke(card, Theme.Accent, 1, 1.2)
		local headingLabel = create("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 7), Size = UDim2.new(1, -24, 0, 18),
			Font = Enum.Font.GothamBold, Text = heading, TextSize = 13, TextColor3 = Theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Parent = card,
		})
		local textLabel = create("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 26), Size = UDim2.new(1, -24, 0, 24),
			Font = Enum.Font.Gotham, Text = text, TextSize = 12, TextColor3 = Theme.SubText, TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
			TextTransparency = 1, Parent = card,
		})
		tween(card, {BackgroundTransparency = 0.1}, 0.25)
		tween(cardStroke, {Transparency = 0.2}, 0.25)
		tween(headingLabel, {TextTransparency = 0}, 0.25)
		tween(textLabel, {TextTransparency = 0}, 0.25)
		task.delay(duration or 4, function()
			if not card.Parent then return end
			tween(card, {BackgroundTransparency = 1}, 0.3)
			tween(cardStroke, {Transparency = 1}, 0.3)
			tween(headingLabel, {TextTransparency = 1}, 0.3)
			tween(textLabel, {TextTransparency = 1}, 0.3)
			task.wait(0.35)
			card:Destroy()
		end)
	end

	--------------------------------------------------------------------------
	-- [4.3] Window:AddTab
	--------------------------------------------------------------------------
	local tabs = {}

	function Window:AddTab(name, icon)
		local Tab = {}
		local entry = {}

		-- Sidebar button ----------------------------------------------------
		local tabButton = create("TextButton", {
			Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 1,
			Text = "", AutoButtonColor = false, Parent = tabList,
		})
		corner(tabButton, 8)
		local tabLabel = create("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -14, 1, 0),
			Font = Enum.Font.GothamMedium, Text = (icon and (icon .. "  ") or "") .. name, TextSize = 13,
			TextColor3 = Theme.SubText, TextXAlignment = Enum.TextXAlignment.Left, Parent = tabButton,
		})
		local tabBar = create("Frame", {
			Size = UDim2.fromOffset(3, 0), Position = UDim2.new(0, 2, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
			BackgroundColor3 = Theme.Accent2, BorderSizePixel = 0, Parent = tabButton,
		})
		corner(tabBar, 2)

		-- Page (scrolling list of elements) -----------------------------------
		local page = create("ScrollingFrame", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
			ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = pages,
		})
		create("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page})
		create("UIPadding", {PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = page})

		entry.button, entry.label, entry.bar, entry.page = tabButton, tabLabel, tabBar, page
		table.insert(tabs, entry)

		local function selectTab()
			for _, other in ipairs(tabs) do
				local active = (other == entry)
				other.page.Visible = active
				tween(other.button, {BackgroundTransparency = active and 0.75 or 1}, 0.2)
				tween(other.label, {TextColor3 = active and Theme.Text or Theme.SubText}, 0.2)
				tween(other.bar, {Size = UDim2.fromOffset(3, active and 16 or 0)}, 0.2)
			end
		end
		tabButton.MouseButton1Click:Connect(selectTab)
		if #tabs == 1 then selectTab() end

		-- Shared element helpers ----------------------------------------------
		local function element(height) -- the rounded card every element lives in
			local card = create("Frame", {
				Size = UDim2.new(1, 0, 0, height), BackgroundColor3 = Theme.Element, BackgroundTransparency = 0.2,
				BorderSizePixel = 0, ClipsDescendants = true, Parent = page,
			})
			corner(card, 8)
			stroke(card, Theme.Stroke, 0.7)
			return card
		end

		local function hover(card, trigger)
			trigger.MouseEnter:Connect(function() tween(card, {BackgroundColor3 = Theme.ElementHover}, 0.15) end)
			trigger.MouseLeave:Connect(function() tween(card, {BackgroundColor3 = Theme.Element}, 0.15) end)
		end

		local function nameLabel(parent, text, y, height)
			return create("TextLabel", {
				BackgroundTransparency = 1, Position = UDim2.fromOffset(12, y or 0), Size = UDim2.new(1, -90, 0, height or 36),
				Font = Enum.Font.GothamMedium, Text = text, TextSize = 13, TextColor3 = Theme.Text,
				TextXAlignment = Enum.TextXAlignment.Left, Parent = parent,
			})
		end

		-- Invisible button laid over an area to catch clicks / drags.
		local function hitbox(parent, position, hitSize)
			return create("TextButton", {
				BackgroundTransparency = 1, Text = "", Position = position or UDim2.new(),
				Size = hitSize or UDim2.fromScale(1, 1), ZIndex = 5, Parent = parent,
			})
		end

		-- ELEMENT: Section header ------------------------------------------------
		function Tab:AddSection(text)
			local row = create("Frame", {Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Parent = page})
			local label = create("TextLabel", {
				BackgroundTransparency = 1, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X,
				Font = Enum.Font.GothamBold, Text = string.upper(text), TextSize = 11, TextColor3 = Theme.Accent2, Parent = row,
			})
			local rule = create("Frame", {
				BackgroundColor3 = Theme.Stroke, BackgroundTransparency = 0.5, BorderSizePixel = 0, Parent = row,
			})
			local function layout() -- keep the line just after the text
				local w = label.AbsoluteSize.X + 10
				rule.Position = UDim2.new(0, w, 0.5, 0)
				rule.Size = UDim2.new(1, -w, 0, 1)
			end
			label:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
			layout()
		end

		-- ELEMENT: Label -----------------------------------------------------------
		function Tab:AddLabel(text)
			local card = element(32)
			local label = create("TextLabel", {
				BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 1, 0),
				Font = Enum.Font.Gotham, Text = text, TextSize = 12, TextColor3 = Theme.SubText, TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left, Parent = card,
			})
			return {Set = function(_, newText) label.Text = newText end}
		end

		-- ELEMENT: Button ------------------------------------------------------------
		function Tab:AddButton(o)
			local card = element(36)
			local hit = hitbox(card)
			nameLabel(card, o.Name or "Button")
			create("TextLabel", {
				BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
				Size = UDim2.fromOffset(20, 20), Font = Enum.Font.GothamBold, Text = "›", TextSize = 20,
				TextColor3 = Theme.Accent2, Parent = card,
			})
			hover(card, hit)
			hit.MouseButton1Click:Connect(function()
				card.BackgroundColor3 = Theme.Accent
				tween(card, {BackgroundColor3 = Theme.Element}, 0.35)
				fire(o.Callback)
			end)
		end

		-- ELEMENT: Toggle ----------------------------------------------------------------
		function Tab:AddToggle(o)
			local state = o.Default or false
			local card = element(36)
			local hit = hitbox(card)
			nameLabel(card, o.Name or "Toggle")

			local pill = create("Frame", {
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(40, 20),
				BackgroundColor3 = Color3.fromRGB(45, 38, 80), BorderSizePixel = 0, Parent = card,
			})
			corner(pill, 10)
			local pillGradient = gradient(pill, Theme.Accent, Theme.Accent2, 0)
			local knob = create("Frame", {
				Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = Color3.new(1, 1, 1),
				BorderSizePixel = 0, Parent = pill,
			})
			corner(knob, 7)
			hover(card, hit)

			local object = {}
			local function render(silent)
				pillGradient.Enabled = state
				pill.BackgroundColor3 = state and Color3.new(1, 1, 1) or Color3.fromRGB(45, 38, 80)
				tween(knob, {Position = state and UDim2.fromOffset(23, 3) or UDim2.fromOffset(3, 3)}, 0.18)
				if not silent then fire(o.Callback, state) end
			end
			function object:Get() return state end
			function object:Set(value) state = value and true or false render() end
			hit.MouseButton1Click:Connect(function() state = not state render() end)
			render(true)
			return object
		end

		-- ELEMENT: Slider ---------------------------------------------------------------------
		function Tab:AddSlider(o)
			local min, max, step = o.Min or 0, o.Max or 100, o.Step or 1
			local value = math.clamp(o.Default or min, min, max)

			local card = element(50)
			nameLabel(card, o.Name or "Slider", 0, 30)
			local valueLabel = create("TextLabel", {
				BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0),
				Size = UDim2.fromOffset(80, 30), Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Theme.Accent2,
				TextXAlignment = Enum.TextXAlignment.Right, Parent = card,
			})
			local track = create("Frame", {
				Position = UDim2.new(0, 12, 0, 35), Size = UDim2.new(1, -24, 0, 6),
				BackgroundColor3 = Theme.Input, BorderSizePixel = 0, Parent = card,
			})
			corner(track, 3)
			local fill = create("Frame", {Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = track})
			corner(fill, 3)
			gradient(fill, Theme.Accent, Theme.Accent2, 0)
			local knob = create("Frame", {
				Size = UDim2.fromOffset(14, 14), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 2, Parent = track,
			})
			corner(knob, 7)
			stroke(knob, Theme.Accent, 0.2, 2)
			local hit = hitbox(card, UDim2.new(0, 0, 0, 24), UDim2.new(1, 0, 1, -24))

			local object = {}
			local function setValue(newValue, silent)
				value = math.clamp(roundTo(newValue - min, step) + min, min, max)
				local alpha = (max == min) and 0 or (value - min) / (max - min)
				fill.Size = UDim2.fromScale(alpha, 1)
				knob.Position = UDim2.new(alpha, -7, 0.5, -7)
				valueLabel.Text = tostring(value) .. (o.Suffix or "")
				if not silent then fire(o.Callback, value) end
			end
			bindDrag(hit, function(pos)
				local alpha = math.clamp((pos.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
				setValue(min + (max - min) * alpha)
			end)
			function object:Get() return value end
			function object:Set(newValue) setValue(newValue) end
			setValue(value, true)
			return object
		end

		-- ELEMENT: Dropdown / MultiDropdown (one builder, `multi` switches mode) ------------------
		local function buildDropdown(o, multi)
			local options = o.Options or {}
			local selected = {} -- set: selected[option] = true
			if multi then
				for _, option in ipairs(o.Default or {}) do selected[option] = true end
			elseif o.Default then
				selected[o.Default] = true
			end

			local listHeight = math.min(#options, 5) * 28
			local card = element(36)
			local header = hitbox(card, UDim2.new(), UDim2.new(1, 0, 0, 36))
			nameLabel(card, o.Name or "Dropdown")
			local currentLabel = create("TextLabel", {
				BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -32, 0, 0),
				Size = UDim2.new(0.5, -40, 0, 36), Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = Theme.SubText,
				TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd, Parent = card,
			})
			local arrow = create("TextLabel", {
				BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 0),
				Size = UDim2.fromOffset(18, 36), Font = Enum.Font.GothamBold, Text = "▾", TextSize = 14,
				TextColor3 = Theme.Accent2, Parent = card,
			})
			hover(card, header)

			local holder = create("ScrollingFrame", {
				Position = UDim2.fromOffset(8, 40), Size = UDim2.new(1, -16, 0, listHeight),
				BackgroundColor3 = Theme.Input, BackgroundTransparency = 0.2, BorderSizePixel = 0,
				ScrollBarThickness = 2, ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = card,
			})
			corner(holder, 6)
			create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = holder})

			local items = {}
			local object = {}

			local function selectedList() -- selections in option order
				local list = {}
				for _, option in ipairs(options) do
					if selected[option] then table.insert(list, option) end
				end
				return list
			end

			local function render(silent)
				for option, item in pairs(items) do
					local on = selected[option] == true
					tween(item.button, {BackgroundTransparency = on and 0.6 or 1}, 0.15)
					item.check.Visible = on
					item.label.TextColor3 = on and Theme.Text or Theme.SubText
				end
				local list = selectedList()
				if multi then
					currentLabel.Text = (#list == 0) and "None" or table.concat(list, ", ")
				else
					currentLabel.Text = list[1] or "Select…"
				end
				if not silent then fire(o.Callback, multi and list or list[1]) end
			end

			for _, option in ipairs(options) do
				local button = create("TextButton", {
					Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 1,
					Text = "", AutoButtonColor = false, Parent = holder,
				})
				local label = create("TextLabel", {
					BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -34, 1, 0),
					Font = Enum.Font.Gotham, Text = tostring(option), TextSize = 12, TextColor3 = Theme.SubText,
					TextXAlignment = Enum.TextXAlignment.Left, Parent = button,
				})
				local check = create("TextLabel", {
					BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 0),
					Size = UDim2.fromOffset(16, 28), Font = Enum.Font.GothamBold, Text = "✓", TextSize = 13,
					TextColor3 = Theme.Accent2, Visible = false, Parent = button,
				})
				items[option] = {button = button, label = label, check = check}

				button.MouseButton1Click:Connect(function()
					if multi then
						selected[option] = (not selected[option]) or nil
					else
						selected = {[option] = true}
					end
					render()
				end)
			end

			local open = false
			header.MouseButton1Click:Connect(function()
				open = not open
				tween(card, {Size = UDim2.new(1, 0, 0, open and (36 + listHeight + 12) or 36)}, 0.22)
				tween(arrow, {Rotation = open and 180 or 0}, 0.22)
			end)

			function object:Get() return multi and selectedList() or selectedList()[1] end
			function object:Set(value)
				selected = {}
				if multi then
					for _, option in ipairs(value) do selected[option] = true end
				else
					selected[value] = true
				end
				render()
			end
			render(true)
			return object
		end
		function Tab:AddDropdown(o) return buildDropdown(o, false) end
		function Tab:AddMultiDropdown(o) return buildDropdown(o, true) end

		-- ELEMENT: Color picker (HSV) ---------------------------------------------------------------
		function Tab:AddColorPicker(o)
			local h, s, v = (o.Default or Theme.Accent):ToHSV()
			local card = element(36)
			local header = hitbox(card, UDim2.new(), UDim2.new(1, 0, 0, 36))
			nameLabel(card, o.Name or "Color")
			local swatch = create("Frame", {
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0, 18), Size = UDim2.fromOffset(34, 18),
				BackgroundColor3 = Color3.fromHSV(h, s, v), BorderSizePixel = 0, Parent = card,
			})
			corner(swatch, 5)
			stroke(swatch, Color3.new(1, 1, 1), 0.6)
			hover(card, header)

			-- Saturation (x) / value (y) square: hue color + white→clear + clear→black overlays
			local square = create("Frame", {
				Position = UDim2.fromOffset(12, 46), Size = UDim2.new(1, -24, 0, 90),
				BackgroundColor3 = Color3.fromHSV(h, 1, 1), BorderSizePixel = 0, Parent = card,
			})
			corner(square, 6)
			local whiteOverlay = create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = square})
			corner(whiteOverlay, 6)
			create("UIGradient", {Transparency = NumberSequence.new(0, 1), Parent = whiteOverlay})
			local blackOverlay = create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, Parent = square})
			corner(blackOverlay, 6)
			create("UIGradient", {Rotation = 90, Transparency = NumberSequence.new(1, 0), Parent = blackOverlay})
			local squareCursor = create("Frame", {Size = UDim2.fromOffset(12, 12), BackgroundTransparency = 1, ZIndex = 3, Parent = square})
			corner(squareCursor, 6)
			stroke(squareCursor, Color3.new(1, 1, 1), 0, 2)
			local squareHit = hitbox(square)

			-- Hue bar
			local hueBar = create("Frame", {
				Position = UDim2.fromOffset(12, 144), Size = UDim2.new(1, -24, 0, 12),
				BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = card,
			})
			corner(hueBar, 6)
			create("UIGradient", {Color = HUE_COLORS, Parent = hueBar})
			local hueCursor = create("Frame", {
				Size = UDim2.fromOffset(6, 16), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5),
				BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 3, Parent = hueBar,
			})
			corner(hueCursor, 3)
			stroke(hueCursor, Color3.new(0, 0, 0), 0.6)
			local hueHit = hitbox(hueBar)

			local hexBox = create("TextBox", {
				Position = UDim2.fromOffset(12, 164), Size = UDim2.new(1, -24, 0, 20), BackgroundColor3 = Theme.Input,
				BackgroundTransparency = 0.2, Font = Enum.Font.Code, TextSize = 12, TextColor3 = Theme.Text,
				ClearTextOnFocus = false, Text = "", Parent = card,
			})
			corner(hexBox, 5)

			local object = {}
			local function render(silent)
				local color = Color3.fromHSV(h, s, v)
				square.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
				squareCursor.Position = UDim2.new(s, -6, 1 - v, -6)
				hueCursor.Position = UDim2.new(h, 0, 0.5, 0)
				swatch.BackgroundColor3 = color
				hexBox.Text = "#" .. color:ToHex():upper()
				if not silent then fire(o.Callback, color) end
			end
			bindDrag(squareHit, function(pos)
				s = math.clamp((pos.X - square.AbsolutePosition.X) / square.AbsoluteSize.X, 0, 1)
				v = 1 - math.clamp((pos.Y - square.AbsolutePosition.Y) / square.AbsoluteSize.Y, 0, 1)
				render()
			end)
			bindDrag(hueHit, function(pos)
				h = math.clamp((pos.X - hueBar.AbsolutePosition.X) / hueBar.AbsoluteSize.X, 0, 1)
				render()
			end)
			hexBox.FocusLost:Connect(function()
				local ok, color = pcall(Color3.fromHex, hexBox.Text)
				if ok and color then h, s, v = color:ToHSV() end
				render()
			end)

			local open = false
			header.MouseButton1Click:Connect(function()
				open = not open
				tween(card, {Size = UDim2.new(1, 0, 0, open and 196 or 36)}, 0.22)
			end)

			function object:Get() return Color3.fromHSV(h, s, v) end
			function object:Set(color) h, s, v = color:ToHSV() render() end
			render(true)
			return object
		end

		-- ELEMENT: Keybind -------------------------------------------------------------------------------
		-- Click the chip, press a key to bind it, Escape cancels.
		function Tab:AddKeybind(o)
			local key = o.Default or Enum.KeyCode.RightShift
			local card = element(36)
			local hit = hitbox(card)
			nameLabel(card, o.Name or "Keybind")
			local chip = create("TextLabel", {
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(104, 22),
				BackgroundColor3 = Theme.Input, BackgroundTransparency = 0.2, Font = Enum.Font.Code, TextSize = 12,
				TextColor3 = Theme.Accent2, TextTruncate = Enum.TextTruncate.AtEnd, Parent = card,
			})
			corner(chip, 6)
			local chipStroke = stroke(chip, Theme.Stroke, 0.5)
			hover(card, hit)

			local listenConnection = nil
			local function render()
				chip.Text = key.Name
				chipStroke.Color = Theme.Stroke
			end
			local function stopListening()
				if listenConnection then listenConnection:Disconnect() listenConnection = nil end
				render()
				-- Small delay so the key that was just bound can't also trigger the menu toggle.
				task.delay(0.15, function() listeningForKey = false end)
			end
			local function startListening()
				listeningForKey = true
				chip.Text = "press a key…"
				chipStroke.Color = Theme.Accent
				listenConnection = connect(UIS.InputBegan, function(input)
					if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
					if input.KeyCode ~= Enum.KeyCode.Escape then
						key = input.KeyCode
						fire(o.Callback, key)
					end
					stopListening()
				end)
			end

			hit.MouseButton1Click:Connect(function()
				if listenConnection then stopListening() else startListening() end
			end)

			local object = {}
			function object:Get() return key end
			function object:Set(keyCode) key = keyCode render() fire(o.Callback, key) end
			render()
			return object
		end

		-- ELEMENT: Config manager -------------------------------------------------------------------------
		-- A name box, a clickable list of saved configs, and Save / Load / Delete buttons.
		--   Click a config  -> selects it (and copies its name into the box)
		--   Save            -> writes every flagged element to the name in the box
		--                      (type a new name to create one, or select one to overwrite it)
		--   Load            -> applies the selected config to the UI
		--   Delete          -> press twice to confirm
		function Tab:AddConfigManager(o)
			o = o or {}
			local folder = o.Folder or Config.ConfigFolder
			local memory = {}      -- fallback storage when there is no file access
			local selected = nil   -- name of the selected config
			local rows = {}        -- name -> {button, label, bar}

			if not HAS_FS then
				Tab:AddLabel("No file access here — configs last this session only.")
			end

			---------------------------------------------------------------- storage
			local function ensureFolder()
				local path = ""
				for part in string.gmatch(folder, "[^/]+") do
					path = (path == "") and part or (path .. "/" .. part)
					if not isfolder(path) then makefolder(path) end
				end
			end
			local function pathFor(name) return folder .. "/" .. name .. ".json" end

			local function listConfigs()
				local names = {}
				if HAS_FS then
					pcall(ensureFolder)
					local ok, files = pcall(listfiles, folder)
					if ok and type(files) == "table" then
						for _, file in ipairs(files) do
							local name = string.match(tostring(file), "([^/\\]+)%.json$")
							if name then table.insert(names, name) end
						end
					end
				else
					for name in pairs(memory) do table.insert(names, name) end
				end
				table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
				return names
			end

			local function writeConfig(name, json)
				if not HAS_FS then memory[name] = json return true end
				return pcall(function()
					ensureFolder()
					writefile(pathFor(name), json)
				end)
			end

			local function readConfig(name)
				if not HAS_FS then
					return memory[name] ~= nil, memory[name]
				end
				return pcall(readfile, pathFor(name))
			end

			local function removeConfig(name)
				if not HAS_FS then memory[name] = nil return true end
				return pcall(delfile, pathFor(name))
			end

			---------------------------------------------------------------- (de)serializing flags
			local function serialize(item)
				local value = item.object:Get()
				if item.kind == "ColorPicker" then return value:ToHex() end
				if item.kind == "Keybind" then return value.Name end
				return value -- Toggle: bool, Slider: number, Dropdown: string, MultiDropdown: table
			end

			-- Returns true if the value was valid and got applied.
			local function apply(item, value)
				local kind, object = item.kind, item.object
				if kind == "Toggle" then
					if type(value) ~= "boolean" then return false end
					object:Set(value)
				elseif kind == "Slider" then
					if type(value) ~= "number" then return false end
					object:Set(value)
				elseif kind == "Dropdown" then
					if type(value) ~= "string" or not table.find(item.options or {}, value) then return false end
					object:Set(value)
				elseif kind == "MultiDropdown" then
					if type(value) ~= "table" then return false end
					local valid = {}
					for _, option in ipairs(value) do
						if table.find(item.options or {}, option) then table.insert(valid, option) end
					end
					object:Set(valid)
				elseif kind == "ColorPicker" then
					if type(value) ~= "string" then return false end
					local ok, color = pcall(Color3.fromHex, value)
					if not ok or not color then return false end
					object:Set(color)
				elseif kind == "Keybind" then
					if type(value) ~= "string" then return false end
					local ok, keyCode = pcall(function() return Enum.KeyCode[value] end)
					if not ok or not keyCode then return false end
					object:Set(keyCode)
				else
					return false
				end
				return true
			end

			local function collect()
				local data = {}
				for flag, item in pairs(registry) do
					local ok, value = pcall(serialize, item)
					if ok and value ~= nil then data[flag] = value end
				end
				return data
			end

			---------------------------------------------------------------- UI
			local card = element(210)

			local nameBox = create("TextBox", {
				Position = UDim2.fromOffset(12, 10), Size = UDim2.new(1, -50, 0, 26), BackgroundColor3 = Theme.Input,
				BackgroundTransparency = 0.2, Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = Theme.Text,
				PlaceholderText = "Config name…", PlaceholderColor3 = Theme.SubText, ClearTextOnFocus = false,
				Text = "", TextXAlignment = Enum.TextXAlignment.Left, Parent = card,
			})
			corner(nameBox, 6)
			create("UIPadding", {PaddingLeft = UDim.new(0, 8), Parent = nameBox})
			stroke(nameBox, Theme.Stroke, 0.6)

			local refreshButton = create("TextButton", {
				AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 10), Size = UDim2.fromOffset(26, 26),
				BackgroundColor3 = Theme.Input, BackgroundTransparency = 0.2, Text = "↻", Font = Enum.Font.GothamBold,
				TextSize = 15, TextColor3 = Theme.Accent2, AutoButtonColor = false, Parent = card,
			})
			corner(refreshButton, 6)
			stroke(refreshButton, Theme.Stroke, 0.6)

			local listHolder = create("ScrollingFrame", {
				Position = UDim2.fromOffset(12, 44), Size = UDim2.new(1, -24, 0, 120),
				BackgroundColor3 = Theme.Input, BackgroundTransparency = 0.2, BorderSizePixel = 0,
				ScrollBarThickness = 2, ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = card,
			})
			corner(listHolder, 6)
			stroke(listHolder, Theme.Stroke, 0.7)
			create("UIListLayout", {Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = listHolder})
			create("UIPadding", {
				PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4),
				Parent = listHolder,
			})

			local emptyLabel = create("TextLabel", {
				BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 44), Size = UDim2.new(1, -24, 0, 120),
				Font = Enum.Font.Gotham, Text = "No configs yet.\nType a name and press Save.", TextSize = 12,
				TextColor3 = Theme.SubText, Parent = card,
			})

			local buttonRow = create("Frame", {
				Position = UDim2.fromOffset(12, 172), Size = UDim2.new(1, -24, 0, 28), BackgroundTransparency = 1, Parent = card,
			})
			create("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
				SortOrder = Enum.SortOrder.LayoutOrder, Parent = buttonRow,
			})
			local function actionButton(text, color, order)
				local button = create("TextButton", {
					Size = UDim2.new(1 / 3, -4, 1, 0), LayoutOrder = order, BackgroundColor3 = Theme.Input,
					BackgroundTransparency = 0.1, Text = text, Font = Enum.Font.GothamBold, TextSize = 12,
					TextColor3 = color, AutoButtonColor = false, Parent = buttonRow,
				})
				corner(button, 7)
				stroke(button, color, 0.5)
				button.MouseEnter:Connect(function()
					tween(button, {BackgroundColor3 = color, TextColor3 = Color3.new(1, 1, 1)}, 0.15)
				end)
				button.MouseLeave:Connect(function()
					tween(button, {BackgroundColor3 = Theme.Input, TextColor3 = color}, 0.15)
				end)
				return button
			end
			local saveButton = actionButton("Save", Theme.Accent, 1)
			local loadButton = actionButton("Load", Theme.Accent2, 2)
			local deleteButton = actionButton("Delete", Theme.Danger, 3)

			refreshButton.MouseEnter:Connect(function() tween(refreshButton, {BackgroundColor3 = Theme.ElementHover}, 0.15) end)
			refreshButton.MouseLeave:Connect(function() tween(refreshButton, {BackgroundColor3 = Theme.Input}, 0.15) end)

			---------------------------------------------------------------- list rendering
			local function notify(heading, text)
				Window:Notify(heading, text, 3)
			end

			local function paintSelection()
				for name, row in pairs(rows) do
					local active = (name == selected)
					tween(row.button, {BackgroundTransparency = active and 0.6 or 1}, 0.15)
					tween(row.label, {TextColor3 = active and Theme.Text or Theme.SubText}, 0.15)
					tween(row.bar, {Size = UDim2.fromOffset(3, active and 14 or 0)}, 0.15)
				end
			end

			local function select(name)
				selected = name
				if name then nameBox.Text = name end
				paintSelection()
			end

			local function refreshList()
				for _, row in pairs(rows) do row.button:Destroy() end
				rows = {}

				local names = listConfigs()
				if selected and not table.find(names, selected) then selected = nil end
				emptyLabel.Visible = (#names == 0)

				for index, name in ipairs(names) do
					local button = create("TextButton", {
						Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 1,
						Text = "", AutoButtonColor = false, LayoutOrder = index, Parent = listHolder,
					})
					corner(button, 5)
					local label = create("TextLabel", {
						BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -16, 1, 0),
						Font = Enum.Font.GothamMedium, Text = name, TextSize = 12, TextColor3 = Theme.SubText,
						TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = button,
					})
					local bar = create("Frame", {
						AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(3, 0),
						BackgroundColor3 = Theme.Accent2, BorderSizePixel = 0, Parent = button,
					})
					corner(bar, 2)
					rows[name] = {button = button, label = label, bar = bar}

					button.MouseEnter:Connect(function()
						if selected ~= name then tween(button, {BackgroundTransparency = 0.85}, 0.12) end
					end)
					button.MouseLeave:Connect(function()
						if selected ~= name then tween(button, {BackgroundTransparency = 1}, 0.12) end
					end)
					button.MouseButton1Click:Connect(function() select(name) end)
				end
				paintSelection()
			end

			---------------------------------------------------------------- actions
			local function save()
				local name = sanitizeName(nameBox.Text)
				if name == "" then name = selected or "" end
				if name == "" then
					notify("Config", "Type a name for the config first.")
					return
				end

				local existed = table.find(listConfigs(), name) ~= nil
				local encoded, json = pcall(function()
					return HttpService:JSONEncode({version = 1, flags = collect()})
				end)
				if not encoded then
					notify("Save failed", "Couldn't encode the settings.")
					return
				end

				local ok, err = writeConfig(name, json)
				if not ok then
					notify("Save failed", tostring(err))
					return
				end
				selected = name
				nameBox.Text = name
				refreshList()
				notify(existed and "Config overwritten" or "Config saved", "\"" .. name .. "\"")
			end

			local function load()
				if not selected then
					notify("Config", "Select a config from the list first.")
					return
				end
				local ok, raw = readConfig(selected)
				if not ok or type(raw) ~= "string" then
					notify("Load failed", "Couldn't read \"" .. selected .. "\".")
					refreshList()
					return
				end
				local decoded, data = pcall(function() return HttpService:JSONDecode(raw) end)
				if not decoded or type(data) ~= "table" or type(data.flags) ~= "table" then
					notify("Load failed", "\"" .. selected .. "\" is corrupted.")
					return
				end

				local count = 0
				for flag, value in pairs(data.flags) do
					local item = registry[flag]
					if item then
						local applied, result = pcall(apply, item, value)
						if applied and result then count += 1 end
					end
				end
				notify("Config loaded", "\"" .. selected .. "\" (" .. count .. " settings)")
			end

			local armToken = 0
			local function resetDelete()
				armToken += 1
				deleteButton.Text = "Delete"
			end
			local function delete()
				if not selected then
					notify("Config", "Select a config from the list first.")
					return
				end
				if deleteButton.Text ~= "Sure?" then
					deleteButton.Text = "Sure?"
					armToken += 1
					local token = armToken
					task.delay(2, function()
						if token == armToken then deleteButton.Text = "Delete" end
					end)
					return
				end
				resetDelete()
				local name = selected
				local ok, err = removeConfig(name)
				if not ok then
					notify("Delete failed", tostring(err))
					return
				end
				selected = nil
				nameBox.Text = ""
				refreshList()
				notify("Config deleted", "\"" .. name .. "\"")
			end

			saveButton.MouseButton1Click:Connect(save)
			loadButton.MouseButton1Click:Connect(load)
			deleteButton.MouseButton1Click:Connect(delete)
			refreshButton.MouseButton1Click:Connect(function()
				refreshList()
			end)

			refreshList()
			return {Refresh = refreshList}
		end

		-- Register every flagged element so the config system can find it.
		-- (Wraps the builders above: same call, plus one extra line of bookkeeping.)
		for method, kind in pairs({
			AddToggle = "Toggle", AddSlider = "Slider", AddDropdown = "Dropdown",
			AddMultiDropdown = "MultiDropdown", AddColorPicker = "ColorPicker", AddKeybind = "Keybind",
		}) do
			local original = Tab[method]
			Tab[method] = function(self, o)
				local object = original(self, o)
				register(o, kind, object)
				return object
			end
		end

		return Tab
	end

	--------------------------------------------------------------------------
	-- [4.4] Window:AddSettingsTab / Window:AddConfigTab
	--------------------------------------------------------------------------
	function Window:AddSettingsTab(name)
		local tab = Window:AddTab(name or "Settings", "⚙")
		tab:AddSection("Menu")
		tab:AddKeybind({
			Name = "Toggle Menu Key",
			Default = toggleKey,
			Callback = function(keyCode)
				Window:SetToggleKey(keyCode)
				Window:Notify("Keybind updated", "Menu now toggles with " .. keyCode.Name .. ".", 3)
			end,
		})
		tab:AddButton({Name = "Unload UI", Callback = function() Window:Destroy() end})
		return tab
	end

	function Window:AddConfigTab(name, o)
		local tab = Window:AddTab(name or "Configs", "◈")
		tab:AddSection("Configs")
		tab:AddConfigManager(o)
		return tab
	end

	return Window
end

------------------------------------------------------------------------------
-- [5] EXAMPLE USAGE
------------------------------------------------------------------------------
--[[
local Nebula = loadstring(game:HttpGet("YOUR_RAW_URL_HERE"))()

local Window = Nebula.CreateWindow({Title = "Nebula", Subtitle = "demo"})

local Main = Window:AddTab("Main", "✦")
Main:AddSection("Movement")
Main:AddToggle({Name = "Speed", Flag = "SpeedOn", Callback = function(on) print("speed", on) end})
Main:AddSlider({Name = "Walk Speed", Flag = "WalkSpeed", Min = 16, Max = 100, Default = 16, Suffix = " st/s"})
Main:AddDropdown({Name = "Mode", Flag = "Mode", Options = {"Legit", "Rage"}, Default = "Legit"})
Main:AddColorPicker({Name = "Accent", Flag = "AccentColor"})

Window:AddConfigTab("Configs")   -- everything above with a Flag is saved/loaded
Window:AddSettingsTab()
]]

return Nebula
