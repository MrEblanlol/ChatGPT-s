-- PRO Combat Assist (LocalScript)
-- Place in StarterPlayerScripts (or StarterGui). Designed for using in your OWN Roblox game.
-- Features: draggable beautiful GUI, Detect(H), Lock(Q) with Team/Dead/Raycast,
-- Prediction, Anti-Shake, Anti-Flick, fast target acquire, mobile & gamepad support, hold/toggle mode.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = Workspace.CurrentCamera

-- =========================
-- == CONFIG (tweakable) ==
-- =========================
local CONFIG = {
    smoothness = 0.12,        -- camera lerp factor (0..1)
    fov = 260,                -- radius in screen pixels (distance from center) to consider targets
    prediction = 0.14,        -- target prediction multiplier (0 = no prediction)
    scanRate = 0.025,         -- seconds between target scans (lower = faster reacquire)
    shakeSmooth = 0.36,       -- anti-shake lerp for target position smoothing (0..1)
    teleportThreshold = 6,    -- meters: if target jumps > this between frames consider teleport and apply extra smoothing
    aimStickiness = 0.85,     -- 0..1 how strongly camera sticks to target after initial lock
    maxCameraLerpPerFrame = 0.45, -- prevent too-large lerps in single frame
    allowHoldMode = true,     -- if true, player can hold lock button for temporary lock
    mobileButtonSize = UDim2.new(0,72,0,72)
}

-- Runtime state
local state = {
    detectOn = false,
    lockOn = false,
    holdMode = false,         -- whether current mode is hold (press+hold) or toggle
    target = nil,
    lastScan = 0,
    lastTargetPos = nil,
    lastTargetVel = Vector3.new(),
    highlights = {},          -- map player -> highlight instance
    uiElements = {}
}

-- =========================
-- == UTILITIES
-- =========================

local function safeDestroy(obj)
    if obj and obj.Destroy then
        pcall(function() obj:Destroy() end)
    end
end

local function isAlive(player)
    if not player or not player.Character then return false end
    local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end
    if humanoid.Health <= 0 then return false end
    if humanoid:GetState() == Enum.HumanoidStateType.Dead then return false end
    return true
end

local function isVisible(part)
    if not part then return false end
    local origin = Camera.CFrame.Position
    local direction = (part.Position - origin)
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = {LocalPlayer.Character}
    params.FilterType = Enum.RaycastFilterType.Blacklist
    local result = Workspace:Raycast(origin, direction, params)
    if result and result.Instance and result.Instance:IsDescendantOf(part.Parent) then
        return true
    end
    return false
end

-- screen distance from center
local function screenDistanceFromCenter(worldPos)
    local posV3, onscreen = Camera:WorldToViewportPoint(worldPos)
    if not onscreen then return math.huge end
    local screen = Vector2.new(posV3.X, posV3.Y)
    local center = Camera.ViewportSize / 2
    return (screen - center).Magnitude
end

-- safely get HumanoidRootPart
local function getRootPart(player)
    if not player or not player.Character then return nil end
    return player.Character:FindFirstChild("HumanoidRootPart")
end

-- =========================
-- == HIGHLIGHT MANAGEMENT
-- =========================

local function createHighlightForPlayer(player)
    if not player or player == LocalPlayer then return end
    if state.highlights[player] and state.highlights[player].Parent then return end

    local h = Instance.new("Highlight")
    h.FillColor = Color3.fromRGB(255, 80, 80)
    h.FillTransparency = 0.45
    h.OutlineColor = Color3.fromRGB(255, 255, 255)
    h.OutlineTransparency = 0.7
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    h.Adornee = player.Character
    h.Parent = player.Character
    state.highlights[player] = h
end

local function removeAllHighlights()
    for p,h in pairs(state.highlights) do
        safeDestroy(h)
        state.highlights[p] = nil
    end
    -- also clear any accidental Highlight objects under workspace
    for _,v in ipairs(Workspace:GetDescendants()) do
        if v:IsA("Highlight") and not v.Parent:IsA("Player") then
            -- skip, keep minimal destruction; highlights we create are parented to Character
        end
    end
end

local function applyHighlightsToAll()
    removeAllHighlights()
    for _,p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            createHighlightForPlayer(p)
        end
    end
end

-- =========================
-- == TARGET ACQUIRE (optimized)
-- =========================

local function getBestTarget()
    local best = nil
    local bestDist = math.huge
    local viewportCenter = Camera.ViewportSize / 2

    -- iterate players once
    for _,p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Team ~= LocalPlayer.Team and isAlive(p) then
            local root = getRootPart(p)
            if root then
                -- quick check: screen distance
                local posV3, onscreen = Camera:WorldToViewportPoint(root.Position)
                if onscreen then
                    local dist = (Vector2.new(posV3.X, posV3.Y) - viewportCenter).Magnitude
                    if dist <= CONFIG.fov and dist < bestDist then
                        -- raycast visibility check (cheap early rejection: use approximate ray direction length)
                        if isVisible(root) then
                            bestDist = dist
                            best = p
                        end
                    end
                end
            end
        end
    end

    return best
end

-- =========================
-- == ANTI-FLICK & PREDICTION HELPERS
-- =========================

local function computeSmoothedPredictedPosition(root)
    local pos = root.Position
    local vel = root.Velocity or Vector3.new()
    local predicted = pos + vel * CONFIG.prediction

    -- teleport detection
    if state.lastTargetPos then
        local lastPos = state.lastTargetPos
        local diff = (predicted - lastPos).Magnitude
        if diff > CONFIG.teleportThreshold then
            -- big jump -> reduce impact (prevent huge flick)
            predicted = lastPos:Lerp(predicted, 0.12)
        end
    end

    -- anti-shake smoothing
    if state.lastTargetPos then
        predicted = state.lastTargetPos:Lerp(predicted, CONFIG.shakeSmooth)
    end

    return predicted, vel
end

-- =========================
-- == CAMERA LERP UTILS
-- =========================

local function lerpCameraTowards(position, lerpFactor)
    local camPos = Camera.CFrame.Position
    local newCF = CFrame.new(camPos, position)
    -- clamp lerpFactor
    if lerpFactor > CONFIG.maxCameraLerpPerFrame then
        lerpFactor = CONFIG.maxCameraLerpPerFrame
    end
    Camera.CFrame = Camera.CFrame:Lerp(newCF, lerpFactor)
end

-- =========================
-- == MAIN RENDER LOOP
-- =========================

RunService.RenderStepped:Connect(function(dt)
    if not state.lockOn then return end

    -- fast reacquire based on scanRate
    if tick() - state.lastScan >= CONFIG.scanRate then
        local newTarget = getBestTarget()
        if newTarget ~= state.target then
            state.target = newTarget
            state.lastTargetPos = nil -- reset smoothing so first frame isn't weird
        end
        state.lastScan = tick()
    end

    local t = state.target
    if not t or not isAlive(t) then
        -- try reacquire immediately
        state.target = getBestTarget()
        state.lastTargetPos = nil
        return
    end

    local root = getRootPart(t)
    if not root then
        state.target = nil
        state.lastTargetPos = nil
        return
    end

    if not isVisible(root) then
        -- target not visible, reacquire
        state.target = getBestTarget()
        state.lastTargetPos = nil
        return
    end

    -- compute predicted & smoothed position + anti-flick
    local predicted, vel = computeSmoothedPredictedPosition(root)
    state.lastTargetPos = predicted
    state.lastTargetVel = vel

    -- dynamic lerp: combine smoothness and stickiness, small faster response initially
    local dynamicLerp = math.clamp(CONFIG.smoothness + (1 - CONFIG.aimStickiness) * 0.12, 0, 1)
    lerpCameraTowards(predicted, dynamicLerp)
end)

-- =========================
-- == GUI (beautiful + draggable + mobile button)
-- =========================

local function createUI()
    local gui = Instance.new("ScreenGui")
    gui.Name = "CombatAssistGUI"
    gui.ResetOnSpawn = false
    gui.Parent = PlayerGui

    -- main frame
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 280, 0, 170)
    frame.Position = UDim2.new(0, 60, 0, 160)
    frame.BackgroundColor3 = Color3.fromRGB(26, 26, 26)
    frame.BorderSizePixel = 0
    frame.AnchorPoint = Vector2.new(0, 0)
    frame.Active = true
    frame.Draggable = true
    frame.Parent = gui

    local uicorner = Instance.new("UICorner", frame)
    uicorner.CornerRadius = UDim.new(0, 10)

    -- title
    local title = Instance.new("TextLabel", frame)
    title.Size = UDim2.new(1, 0, 0, 40)
    title.Position = UDim2.new(0, 0, 0, 0)
    title.BackgroundColor3 = Color3.fromRGB(38, 38, 38)
    title.Text = "⚔️ Combat Assist PRO"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 18
    title.BorderSizePixel = 0
    local titleCorner = Instance.new("UICorner", title)
    titleCorner.CornerRadius = UDim.new(0, 10)

    -- detect toggle button
    local detectBtn = Instance.new("TextButton", frame)
    detectBtn.Size = UDim2.new(0.46, 0, 0, 34)
    detectBtn.Position = UDim2.new(0.02, 0, 0, 48)
    detectBtn.Text = "Detect: OFF (H)"
    detectBtn.Font = Enum.Font.Gotham
    detectBtn.TextSize = 14
    detectBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
    detectBtn.TextColor3 = Color3.fromRGB(255, 180, 180)
    detectBtn.AutoButtonColor = true
    local dCorner = Instance.new("UICorner", detectBtn)
    dCorner.CornerRadius = UDim.new(0, 8)

    -- lock toggle/hold button
    local lockBtn = Instance.new("TextButton", frame)
    lockBtn.Size = UDim2.new(0.46, 0, 0, 34)
    lockBtn.Position = UDim2.new(0.52, 0, 0, 48)
    lockBtn.Text = "Lock: OFF (Q)"
    lockBtn.Font = Enum.Font.Gotham
    lockBtn.TextSize = 14
    lockBtn.BackgroundColor3 = Color3.fromRGB(30, 60, 30)
    lockBtn.TextColor3 = Color3.fromRGB(180, 255, 180)
    lockBtn.AutoButtonColor = true
    local lCorner = Instance.new("UICorner", lockBtn)
    lCorner.CornerRadius = UDim.new(0, 8)

    -- slider labels + boxes
    local smoothLabel = Instance.new("TextLabel", frame)
    smoothLabel.Size = UDim2.new(0.5, -12, 0, 26)
    smoothLabel.Position = UDim2.new(0.02, 0, 0, 92)
    smoothLabel.Text = "Smoothness"
    smoothLabel.TextColor3 = Color3.fromRGB(220,220,220)
    smoothLabel.BackgroundTransparency = 1
    smoothLabel.Font = Enum.Font.Gotham
    smoothLabel.TextSize = 13

    local smoothBox = Instance.new("TextBox", frame)
    smoothBox.Size = UDim2.new(0.5, -12, 0, 26)
    smoothBox.Position = UDim2.new(0.48, 0, 0, 92)
    smoothBox.Text = tostring(CONFIG.smoothness)
    smoothBox.ClearTextOnFocus = false
    smoothBox.PlaceholderText = "0.01 - 1.0"
    smoothBox.Font = Enum.Font.Gotham
    smoothBox.TextSize = 13
    smoothBox.BackgroundColor3 = Color3.fromRGB(40,40,40)
    local sbCorner = Instance.new("UICorner", smoothBox)
    sbCorner.CornerRadius = UDim.new(0,6)

    local fovLabel = Instance.new("TextLabel", frame)
    fovLabel.Size = UDim2.new(0.5, -12, 0, 26)
    fovLabel.Position = UDim2.new(0.02, 0, 0, 126)
    fovLabel.Text = "FOV(px)"
    fovLabel.TextColor3 = Color3.fromRGB(220,220,220)
    fovLabel.BackgroundTransparency = 1
    fovLabel.Font = Enum.Font.Gotham
    fovLabel.TextSize = 13

    local fovBox = Instance.new("TextBox", frame)
    fovBox.Size = UDim2.new(0.5, -12, 0, 26)
    fovBox.Position = UDim2.new(0.48, 0, 0, 126)
    fovBox.Text = tostring(CONFIG.fov)
    fovBox.ClearTextOnFocus = false
    fovBox.PlaceholderText = "e.g. 260"
    fovBox.Font = Enum.Font.Gotham
    fovBox.TextSize = 13
    fovBox.BackgroundColor3 = Color3.fromRGB(40,40,40)
    local fbCorner = Instance.new("UICorner", fovBox)
    fbCorner.CornerRadius = UDim.new(0,6)

    -- mobile lock button (bottom-right)
    local mobileButton = Instance.new("ImageButton", gui)
    mobileButton.Name = "MobileLockButton"
    mobileButton.AnchorPoint = Vector2.new(1,1)
    mobileButton.Size = CONFIG.mobileButtonSize
    mobileButton.Position = UDim2.new(1, -18, 1, -18)
    mobileButton.BackgroundColor3 = Color3.fromRGB(45,45,45)
    local mbCorner = Instance.new("UICorner", mobileButton)
    mbCorner.CornerRadius = UDim.new(0, 12)
    mobileButton.AutoButtonColor = true
    mobileButton.Image = "" -- keep blank so it is neutral; developers can set image asset if they want
    mobileButton.Visible = UIS.TouchEnabled -- only show on touch devices

    local mobileLabel = Instance.new("TextLabel", mobileButton)
    mobileLabel.Size = UDim2.new(1,0,1,0)
    mobileLabel.BackgroundTransparency = 1
    mobileLabel.Text = "LOCK"
    mobileLabel.Font = Enum.Font.GothamBold
    mobileLabel.TextSize = 18
    mobileLabel.TextColor3 = Color3.fromRGB(200,255,180)

    -- store ui refs
    state.uiElements = {
        gui = gui, frame = frame, title = title,
        detectBtn = detectBtn, lockBtn = lockBtn,
        smoothBox = smoothBox, fovBox = fovBox,
        mobileButton = mobileButton
    }

    -- small button animations
    local function pulse(btn)
        local t = TweenService:Create(btn, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0.15})
        t:Play()
        t.Completed:Wait()
        local t2 = TweenService:Create(btn, TweenInfo.new(0.12), {BackgroundTransparency = 0})
        t2:Play()
    end

    -- click handlers
    detectBtn.MouseButton1Click:Connect(function()
        state.detectOn = not state.detectOn
        if state.detectOn then
            detectBtn.Text = "Detect: ON (H)"
            detectBtn.BackgroundColor3 = Color3.fromRGB(120, 30, 30)
            applyHighlightsToAll()
        else
            detectBtn.Text = "Detect: OFF (H)"
            detectBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
            removeAllHighlights()
        end
        pulse(detectBtn)
    end)

    lockBtn.MouseButton1Click:Connect(function()
        if CONFIG.allowHoldMode and state.holdMode then
            -- hold mode: toggle holdMode state (we keep toggle semantics here)
            -- but allow switching via long press: here we use normal toggle
        end
        state.lockOn = not state.lockOn
        if state.lockOn then
            lockBtn.Text = "Lock: ON (Q)"
            lockBtn.BackgroundColor3 = Color3.fromRGB(30, 120, 30)
            -- acquire target immediately
            state.target = getBestTarget()
            state.lastTargetPos = nil
        else
            lockBtn.Text = "Lock: OFF (Q)"
            lockBtn.BackgroundColor3 = Color3.fromRGB(30, 60, 30)
            state.target = nil
            state.lastTargetPos = nil
        end
        pulse(lockBtn)
    end)

    -- mobile button tap (acts like pressing Q)
    mobileButton.Activated:Connect(function()
        state.lockOn = not state.lockOn
        if state.lockOn then
            state.target = getBestTarget()
            state.lastTargetPos = nil
            state.uiElements.lockBtn.Text = "Lock: ON (Q)"
            state.uiElements.lockBtn.BackgroundColor3 = Color3.fromRGB(30, 120, 30)
        else
            state.target = nil
            state.lastTargetPos = nil
            state.uiElements.lockBtn.Text = "Lock: OFF (Q)"
            state.uiElements.lockBtn.BackgroundColor3 = Color3.fromRGB(30, 60, 30)
        end
    end)

    -- numeric inputs
    smoothBox.FocusLost:Connect(function(enter)
        local n = tonumber(smoothBox.Text)
        if n and n > 0 and n <= 1.0 then
            CONFIG.smoothness = n
        else
            smoothBox.Text = tostring(CONFIG.smoothness)
        end
    end)
    fovBox.FocusLost:Connect(function(enter)
        local n = tonumber(fovBox.Text)
        if n and n >= 50 and n <= 1000 then
            CONFIG.fov = n
        else
            fovBox.Text = tostring(CONFIG.fov)
        end
    end)

    return gui
end

-- =========================
-- == INPUT (keyboard / gamepad)
-- =========================

-- keyboard toggles
UIS.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType == Enum.UserInputType.Keyboard then
        local kc = input.KeyCode
        if kc == Enum.KeyCode.H then
            -- toggle detect
            state.detectOn = not state.detectOn
            if state.detectOn then
                state.uiElements.detectBtn.Text = "Detect: ON (H)"
                state.uiElements.detectBtn.BackgroundColor3 = Color3.fromRGB(120, 30, 30)
                applyHighlightsToAll()
            else
                state.uiElements.detectBtn.Text = "Detect: OFF (H)"
                state.uiElements.detectBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
                removeAllHighlights()
            end
        elseif kc == Enum.KeyCode.Q then
            -- lock toggle / hold: if hold mode, we set state in InputEnded
            if CONFIG.allowHoldMode and state.holdMode then
                state.lockOn = true
                state.target = getBestTarget()
                state.lastTargetPos = nil
                state.uiElements.lockBtn.Text = "Lock: ON (Q)"
                state.uiElements.lockBtn.BackgroundColor3 = Color3.fromRGB(30, 120, 30)
            else
                state.lockOn = not state.lockOn
                if state.lockOn then
                    state.target = getBestTarget()
                    state.lastTargetPos = nil
                    state.uiElements.lockBtn.Text = "Lock: ON (Q)"
                    state.uiElements.lockBtn.BackgroundColor3 = Color3.fromRGB(30, 120, 30)
                else
                    state.target = nil
                    state.lastTargetPos = nil
                    state.uiElements.lockBtn.Text = "Lock: OFF (Q)"
                    state.uiElements.lockBtn.BackgroundColor3 = Color3.fromRGB(30, 60, 30)
                end
            end
        elseif kc == Enum.KeyCode.LeftShift then
            -- toggle hold/toggle mode quickly for power users
            state.holdMode = not state.holdMode
            -- little visual feedback
            local text = state.holdMode and "HOLD MODE" or "TOGGLE MODE"
            local toast = Instance.new("TextLabel", state.uiElements.gui)
            toast.Text = text
            toast.Size = UDim2.new(0,160,0,40)
            toast.Position = UDim2.new(0, 60, 0, 140)
            toast.BackgroundColor3 = Color3.fromRGB(20,20,20)
            toast.TextColor3 = Color3.new(1,1,1)
            toast.Font = Enum.Font.GothamBold
            toast.TextSize = 14
            local tcorner = Instance.new("UICorner", toast)
            tcorner.CornerRadius = UDim.new(0,6)
            delay(0.9, function() safeDestroy(toast) end)
        end
    elseif input.UserInputType == Enum.UserInputType.Gamepad1 then
        -- gamepad buttons: support common buttons (R2, R1, ButtonA) as lock toggle
        local kc = input.KeyCode
        if kc == Enum.KeyCode.ButtonR2 or kc == Enum.KeyCode.ButtonR1 or kc == Enum.KeyCode.ButtonA then
            if CONFIG.allowHoldMode and state.holdMode then
                state.lockOn = true
                state.target = getBestTarget()
                state.lastTargetPos = nil
            else
                state.lockOn = not state.lockOn
                if state.lockOn then
                    state.target = getBestTarget()
                    state.lastTargetPos = nil
                else
                    state.target = nil
                    state.lastTargetPos = nil
                end
            end
        end
    end
end)

-- InputEnded for hold mode release
UIS.InputEnded:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType == Enum.UserInputType.Keyboard then
        if input.KeyCode == Enum.KeyCode.Q and CONFIG.allowHoldMode and state.holdMode then
            state.lockOn = false
            state.target = nil
            state.lastTargetPos = nil
            state.uiElements.lockBtn.Text = "Lock: OFF (Q)"
            state.uiElements.lockBtn.BackgroundColor3 = Color3.fromRGB(30, 60, 30)
        end
    elseif input.UserInputType == Enum.UserInputType.Gamepad1 then
        local kc = input.KeyCode
        if (kc == Enum.KeyCode.ButtonR2 or kc == Enum.KeyCode.ButtonR1 or kc == Enum.KeyCode.ButtonA)
           and CONFIG.allowHoldMode and state.holdMode then
            state.lockOn = false
            state.target = nil
            state.lastTargetPos = nil
            state.uiElements.lockBtn.Text = "Lock: OFF (Q)"
            state.uiElements.lockBtn.BackgroundColor3 = Color3.fromRGB(30, 60, 30)
        end
    end
end)

-- =========================
-- == PLAYER / CLEANUP EVENTS
-- =========================

Players.PlayerRemoving:Connect(function(plr)
    if state.highlights[plr] then
        safeDestroy(state.highlights[plr])
        state.highlights[plr] = nil
    end
end)

Players.PlayerAdded:Connect(function(plr)
    -- ensure we attach highlight to new player's character when they spawn if detect is on
    plr.CharacterAdded:Connect(function(char)
        if state.detectOn then
            createHighlightForPlayer(plr)
        end
    end)
end)

-- =========================
-- == INIT
-- =========================

local ui = createUI()

-- initial UI state
if state.detectOn then
    state.uiElements.detectBtn.Text = "Detect: ON (H)"
else
    state.uiElements.detectBtn.Text = "Detect: OFF (H)"
end
state.uiElements.lockBtn.Text = "Lock: OFF (Q)"

-- Ensure mobile button visibility toggles when device changes
UIS:GetPropertyChangedSignal("TouchEnabled"):Connect(function()
    state.uiElements.mobileButton.Visible = UIS.TouchEnabled
end)

-- End of script
