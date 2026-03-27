--!strict
-- GoalkeeperAI.lua

local Players = game:GetService("Players")

export type AIConfig = {
	-- Core behavior
	reactionTimeMin: number,
	reactionTimeMax: number,
	predictInterval: number,
	predictHorizon: number,

	-- Positioning
	positioningSpeed: number,
	positioningResponsiveness: number,
	neutralDepth: number,
	stepOutDepth: number,
	farDistance: number,
	goalSideMargin: number,
	penaltyDepth: number,
	penaltyHalfWidth: number,

	-- Threat / saves
	threatTime: number,
	saveRange: number,
	catchRange: number,
	catchMaxBallSpeed: number,
	catchMaxHeight: number,
	punchRange: number,
	punchMaxHeight: number,
	punchSpeed: number,
	punchUp: number,

	-- Aerial + hitbox tuning
	saveHitboxSize: Vector3,
	saveHitboxOffset: Vector3,
	aerialSaveExtraRange: number,
	jumpLeadExtra: number,

	-- Jump
	jumpPower: number,
	jumpBoostVel: number,
	jumpAirControlTime: number,
	normalReachHeight: number,
	jumpLeadTime: number,
	jumpCooldown: number,

	-- Dash
	dashSpeed: number,
	dashDuration: number,
	dashCooldown: number,
	dashTriggerTime: number,
	dashTriggerDist: number,
	dashMaxDist: number,

	-- Ball hold + distribution
	holdMin: number,
	holdMax: number,
	lobMinPower: number,
	lobMaxPower: number,
	lobArcHeight: number,
	lobPowerRand: number,
	lobDirRand: number,
}

export type GameConfig = {
	FieldLength: number,
	GoalWidth: number,
	GoalHeight: number,
	Spawns: any,
	Teams: any,
}

export type Deps = {
	ball: BasePart,
	gameConfig: GameConfig,
	getGKOccupied: (teamKey: string) -> boolean,
	getTeamPlayers: (teamKey: string) -> { Player },
	setBallHeld: (held: boolean, teamKey: string?) -> (),
	markLastTouch: (teamKey: string, playerName: string?) -> (),
	isBallLocked: () -> boolean,
	aiConfig: AIConfig?,
}

type Prediction = {
	valid: boolean,
	tImpact: number,
	point: Vector3,
	speed: number,
}

type Keeper = {
	teamKey: string,
	model: Model,
	hum: Humanoid,
	hrp: BasePart,
	torso: BasePart,
	groundY: number,

	alignPos: AlignPosition,
	alignOri: AlignOrientation,
	rootAtt: Attachment,

	holdTorsoAtt: Attachment?,
	holdBallAtt: Attachment?,
	holdAlignPos: AlignPosition?,
	holdAlignOri: AlignOrientation?,

	nextPredictT: number,
	pred: Prediction,

	reactAt: number?,
	reactPoint: Vector3?,

	jumpCdUntil: number,
	jumpAirUntil: number,
	dashCdUntil: number,

	holding: boolean,
	throwAt: number?,
}

local DEFAULT: AIConfig = {
	-- Reaction / prediction
	reactionTimeMin = 0.15,
	reactionTimeMax = 0.35,
	predictInterval = 0.12,
	predictHorizon = 2.2,

	-- Positioning
	positioningSpeed = 22,
	positioningResponsiveness = 35,
	neutralDepth = 4.0,
	stepOutDepth = 5.5,
	farDistance = 140,
	goalSideMargin = 1.5,
	penaltyDepth = 70,
	penaltyHalfWidth = 70,

	-- Saves
	threatTime = 1.25,
	saveRange = 10,
	catchRange = 6.5,
	catchMaxBallSpeed = 58,
	catchMaxHeight = 6.2,
	punchRange = 9.5,
	punchMaxHeight = 10.5,
	punchSpeed = 95,
	punchUp = 18,

	-- Aerial + hitbox
	saveHitboxSize = Vector3.new(5.2, 6.8, 6.0),
	saveHitboxOffset = Vector3.new(0, 1.35, 0),
	aerialSaveExtraRange = 2.25,
	jumpLeadExtra = 0.28,

	-- Jump
	jumpPower = 62,
	jumpBoostVel = 16,
	jumpAirControlTime = 0.22,
	normalReachHeight = 5.4,
	jumpLeadTime = 0.42,
	jumpCooldown = 0.9,

	-- Dash
	dashSpeed = 85,
	dashDuration = 0.18,
	dashCooldown = 1.1,
	dashTriggerTime = 0.55,
	dashTriggerDist = 4.5,
	dashMaxDist = 15,

	-- Hold + distribute
	holdMin = 0.5,
	holdMax = 1.2,
	lobMinPower = 38,
	lobMaxPower = 78,
	lobArcHeight = 16,
	lobPowerRand = 0.05,
	lobDirRand = 0.06,
}

local function clamp(n: number, a: number, b: number): number
	return math.max(a, math.min(b, n))
end

local function randRange(a: number, b: number): number
	return a + (b - a) * math.random()
end

local function safeUnit(v: Vector3, fallback: Vector3): Vector3
	return v.Magnitude > 1e-4 and v.Unit or fallback
end

local function destroyIf(inst: Instance?)
	if inst and inst.Parent then
		inst:Destroy()
	end
end

local function nearestPlayerDist(pos: Vector3): number
	local minDist = math.huge
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hum and hum.Health > 0 and hrp then
			local d = (hrp.Position - pos).Magnitude
			if d < minDist then
				minDist = d
			end
		end
	end
	return minDist
end

local GoalkeeperAI = {}
GoalkeeperAI.__index = GoalkeeperAI

-- ----------------------------
-- R6 NPC builder
-- ----------------------------
local function makePart(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	canCollide: boolean,
	transparency: number?
): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = canCollide
	p.Transparency = transparency or 0
	p.Parent = parent
	return p
end

local function motor(p0: BasePart, p1: BasePart, name: string, c0: CFrame, c1: CFrame)
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = p0
	m.Part1 = p1
	m.C0 = c0
	m.C1 = c1
	m.Parent = p0
	return m
end

local function buildR6Goalkeeper(teamKey: string, spawnCF: CFrame, teamColor: Color3, jumpPower: number): (Model, Humanoid, BasePart, BasePart)
	local model = Instance.new("Model")
	model.Name = teamKey .. "_GoalkeeperNPC"

	local hrp = makePart(model, "HumanoidRootPart", Vector3.new(2, 2, 1), spawnCF, Color3.new(1, 1, 1), false, 1)
	hrp.CanQuery = false

	local torso = makePart(model, "Torso", Vector3.new(2, 2, 1), spawnCF, teamColor, true)
	local head = makePart(model, "Head", Vector3.new(2, 1, 1), spawnCF * CFrame.new(0, 1.5, 0), Color3.new(1, 0.85, 0.75), true)

	local la = makePart(model, "Left Arm", Vector3.new(1, 2, 1), spawnCF * CFrame.new(-1.5, 0, 0), teamColor, true)
	local ra = makePart(model, "Right Arm", Vector3.new(1, 2, 1), spawnCF * CFrame.new(1.5, 0, 0), teamColor, true)
	local ll = makePart(model, "Left Leg", Vector3.new(1, 2, 1), spawnCF * CFrame.new(-0.5, -2, 0), Color3.new(0.15, 0.15, 0.15), true)
	local rl = makePart(model, "Right Leg", Vector3.new(1, 2, 1), spawnCF * CFrame.new(0.5, -2, 0), Color3.new(0.15, 0.15, 0.15), true)

	local hum = Instance.new("Humanoid")
	hum.Name = "Humanoid"
	hum.RigType = Enum.HumanoidRigType.R6
	hum.AutoRotate = false
	hum.WalkSpeed = 0
	hum.JumpPower = jumpPower
	hum.Parent = model

	motor(hrp, torso, "RootJoint", CFrame.new(), CFrame.new())
	motor(torso, head, "Neck", CFrame.new(0, 1, 0), CFrame.new(0, -0.5, 0))
	motor(torso, la, "Left Shoulder", CFrame.new(-1, 0.5, 0), CFrame.new(0.5, 0.5, 0))
	motor(torso, ra, "Right Shoulder", CFrame.new(1, 0.5, 0), CFrame.new(-0.5, 0.5, 0))
	motor(torso, ll, "Left Hip", CFrame.new(-0.5, -1, 0), CFrame.new(0, 1, 0))
	motor(torso, rl, "Right Hip", CFrame.new(0.5, -1, 0), CFrame.new(0, 1, 0))

	local face = Instance.new("Decal")
	face.Name = "face"
	face.Texture = "rbxasset://textures/face.png"
	face.Parent = head

	model.PrimaryPart = hrp
	model.Parent = workspace
	model:PivotTo(spawnCF)

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d:SetNetworkOwner(nil)
		end
	end

	return model, hum, hrp, torso
end

-- ----------------------------
-- GoalkeeperAI implementation
-- ----------------------------
function GoalkeeperAI.new(deps: Deps)
	assert(deps and deps.ball and deps.gameConfig, "GoalkeeperAI.new requires ball + gameConfig")
	assert(typeof(deps.getGKOccupied) == "function", "GoalkeeperAI.new requires getGKOccupied(teamKey)")
	assert(typeof(deps.getTeamPlayers) == "function", "GoalkeeperAI.new requires getTeamPlayers(teamKey)")

	local self = setmetatable({}, GoalkeeperAI)
	self._ball = deps.ball
	self._game = deps.gameConfig

	self._cfg = table.clone(DEFAULT)
	if deps.aiConfig then
		for k, v in pairs(deps.aiConfig :: any) do
			(self._cfg :: any)[k] = v
		end
	end

	self._getGKOccupied = deps.getGKOccupied
	self._getTeamPlayers = deps.getTeamPlayers
	self._setBallHeld = deps.setBallHeld or function() end
	self._markLastTouch = deps.markLastTouch or function() end
	self._isBallLocked = deps.isBallLocked or function() return false end

	self._keepers = {} :: { [string]: Keeper? }

	self._ball:SetAttribute("HeldByGK", false)
	self._ball:SetAttribute("HeldByGKTeam", nil)

	self:_refreshKeeper("Home")
	self:_refreshKeeper("Away")

	return self
end

function GoalkeeperAI:Destroy()
	for _, teamKey in ipairs({ "Home", "Away" }) do
		self:_destroyKeeper(teamKey)
	end
end

function GoalkeeperAI:ForceRefresh()
	self:_refreshKeeper("Home")
	self:_refreshKeeper("Away")
end

function GoalkeeperAI:_destroyKeeper(teamKey: string)
	local k = self._keepers[teamKey]
	if not k then return end

	if k.holding then
		self:_releaseBall(k)
	end

	if k.model and k.model.Parent then
		k.model:Destroy()
	end
	self._keepers[teamKey] = nil
end

function GoalkeeperAI:_refreshKeeper(teamKey: string)
	local occupied = self._getGKOccupied(teamKey)
	local existing = self._keepers[teamKey]

	if occupied then
		if existing then
			self:_destroyKeeper(teamKey)
		end
		return
	end

	if existing and existing.model and existing.model.Parent then
		return
	end

	local spawnPos = self._game.Spawns[teamKey] and self._game.Spawns[teamKey].GK
	if not spawnPos then return end

	local goalX = (teamKey == "Home") and -(self._game.FieldLength / 2) or (self._game.FieldLength / 2)
	local forwardSign = (teamKey == "Home") and 1 or -1

	local spawnCF = CFrame.lookAt(
		Vector3.new(goalX + forwardSign * (self._cfg.neutralDepth + 1), spawnPos.Y, spawnPos.Z),
		Vector3.new(goalX + forwardSign * 40, spawnPos.Y, 0)
	)

	local teamColor: Color3 = self._game.Teams[teamKey].Color3
	local model, hum, hrp, torso = buildR6Goalkeeper(teamKey, spawnCF, teamColor, self._cfg.jumpPower)

	local rootAtt = Instance.new("Attachment")
	rootAtt.Name = "GK_RootAtt"
	rootAtt.Parent = hrp

	local ap = Instance.new("AlignPosition")
	ap.Name = "GK_AlignPosition"
	ap.Mode = Enum.PositionAlignmentMode.OneAttachment
	ap.Attachment0 = rootAtt
	ap.MaxForce = 1e6
	ap.MaxVelocity = self._cfg.positioningSpeed
	ap.Responsiveness = self._cfg.positioningResponsiveness
	ap.RigidityEnabled = false
	ap.ApplyAtCenterOfMass = true
	ap.Parent = hrp

	local ao = Instance.new("AlignOrientation")
	ao.Name = "GK_AlignOrientation"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = rootAtt
	ao.MaxTorque = 1e7
	ao.Responsiveness = 30
	ao.PrimaryAxisOnly = false
	ao.Parent = hrp

	local k: Keeper = {
		teamKey = teamKey,
		model = model,
		hum = hum,
		hrp = hrp,
		torso = torso,
		groundY = spawnPos.Y,

		alignPos = ap,
		alignOri = ao,
		rootAtt = rootAtt,

		holdTorsoAtt = nil,
		holdBallAtt = nil,
		holdAlignPos = nil,
		holdAlignOri = nil,

		nextPredictT = 0,
		pred = { valid = false, tImpact = 0, point = Vector3.zero, speed = 0 },

		reactAt = nil,
		reactPoint = nil,

		jumpCdUntil = 0,
		jumpAirUntil = 0,
		dashCdUntil = 0,

		holding = false,
		throwAt = nil,
	}

	self._keepers[teamKey] = k
end

function GoalkeeperAI:_goalParams(teamKey: string): (number, number, Vector3)
	local hl = self._game.FieldLength / 2
	local goalX = (teamKey == "Home") and -hl or hl
	local forwardSign = (teamKey == "Home") and 1 or -1
	local goalCenter = Vector3.new(goalX, 0, 0)
	return goalX, forwardSign, goalCenter
end

function GoalkeeperAI:_updatePrediction(k: Keeper, _now: number)
	local ball = self._ball
	local pos = ball.Position
	local vel = ball.AssemblyLinearVelocity
	local speed = vel.Magnitude
	local g = workspace.Gravity

	local goalX, forwardSign = self:_goalParams(k.teamKey)
	local keeperX = goalX + forwardSign * self._cfg.neutralDepth
	local vx = vel.X

	if math.abs(vx) < 1 then
		k.pred = { valid = false, tImpact = 0, point = Vector3.zero, speed = speed }
		return
	end

	if (goalX - pos.X) * vx <= 0 then
		k.pred = { valid = false, tImpact = 0, point = Vector3.zero, speed = speed }
		return
	end

	local tGoal = (goalX - pos.X) / vx
	local tKeeper = (keeperX - pos.X) / vx

	if tGoal <= 0 or tKeeper <= 0 or tKeeper > self._cfg.predictHorizon then
		k.pred = { valid = false, tImpact = 0, point = Vector3.zero, speed = speed }
		return
	end

	local goalY = pos.Y + vel.Y * tGoal - 0.5 * g * tGoal * tGoal
	local goalZ = pos.Z + vel.Z * tGoal

	local keeperY = pos.Y + vel.Y * tKeeper - 0.5 * g * tKeeper * tKeeper
	local keeperZ = pos.Z + vel.Z * tKeeper

	local goalHit = Vector3.new(goalX, goalY, goalZ)
	local keeperHit = Vector3.new(keeperX, keeperY, keeperZ)

	local halfW = self._game.GoalWidth / 2
	local inMouth = math.abs(goalHit.Z) <= (halfW + 2)

	k.pred = {
		valid = inMouth and speed > 6,
		tImpact = tKeeper,
		point = keeperHit,
		speed = speed,
	}
end

function GoalkeeperAI:_desiredPosition(k: Keeper): Vector3
	local ballPos = self._ball.Position
	local goalX, forwardSign = self:_goalParams(k.teamKey)
	local halfW = self._game.GoalWidth / 2

	local depth = (ballPos.X - goalX) * forwardSign
	local farAlpha = clamp(1 - (depth / self._cfg.farDistance), 0, 1)
	local zTrack = clamp(ballPos.Z, -halfW + self._cfg.goalSideMargin, halfW - self._cfg.goalSideMargin)
	zTrack *= (0.25 + 0.75 * farAlpha)

	local x = goalX + forwardSign * self._cfg.neutralDepth

	if depth > 0 and depth <= self._cfg.penaltyDepth and math.abs(ballPos.Z) <= self._cfg.penaltyHalfWidth then
		local stepAlpha = 1 - (depth / self._cfg.penaltyDepth)
		x = goalX + forwardSign * (self._cfg.neutralDepth + self._cfg.stepOutDepth * stepAlpha)
	end

	if depth < -1 then
		x = goalX + forwardSign * self._cfg.neutralDepth
		zTrack = 0
	end

	return Vector3.new(x, k.groundY, zTrack)
end

function GoalkeeperAI:_setKeeperTarget(k: Keeper, target: Vector3, stickToGround: boolean)
	local y = k.groundY
	local now = os.clock()

	local st = k.hum:GetState()
	local airborne = (st == Enum.HumanoidStateType.Jumping)
		or (st == Enum.HumanoidStateType.Freefall)
		or (st == Enum.HumanoidStateType.FallingDown)

	if not stickToGround and (airborne or now < k.jumpAirUntil) then
		y = math.max(k.groundY, k.hrp.Position.Y - 0.9)
	end

	k.alignPos.Position = Vector3.new(target.X, y, target.Z)
end

function GoalkeeperAI:_faceBall(k: Keeper)
	local p = k.hrp.Position
	local b = self._ball.Position
	k.alignOri.CFrame = CFrame.lookAt(p, Vector3.new(b.X, p.Y, b.Z))
end

function GoalkeeperAI:_clearGuidanceForBall()
	for _, child in ipairs(self._ball:GetChildren()) do
		if child:IsA("Attachment") and child.Name == "KickAtt" then
			child:Destroy()
		elseif child:IsA("LinearVelocity") then
			child:Destroy()
		end
	end
end

function GoalkeeperAI:_ballDistToSaveBox(k: Keeper): number
	local torsoCF = k.torso.CFrame
	local ballLocal = torsoCF:PointToObjectSpace(self._ball.Position)

	local center = self._cfg.saveHitboxOffset
	local half = self._cfg.saveHitboxSize * 0.5
	local rel = ballLocal - center

	local dx = math.max(math.abs(rel.X) - half.X, 0)
	local dy = math.max(math.abs(rel.Y) - half.Y, 0)
	local dz = math.max(math.abs(rel.Z) - half.Z, 0)

	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function GoalkeeperAI:_holdBall(k: Keeper)
	if k.holding then return end
	if not self._ball.Parent then return end

	self:_clearGuidanceForBall()
	self._markLastTouch(k.teamKey, nil)

	self._ball.AssemblyLinearVelocity = Vector3.zero
	self._ball.AssemblyAngularVelocity = Vector3.zero
	self._ball:SetNetworkOwner(nil)

	k.holding = true
	self._ball.CanCollide = false
	self._setBallHeld(true, k.teamKey)
	self._ball:SetAttribute("HeldByGK", true)
	self._ball:SetAttribute("HeldByGKTeam", k.teamKey)

	local torsoAtt = Instance.new("Attachment")
	torsoAtt.Name = "GK_HoldTorsoAtt"
	torsoAtt.Position = Vector3.new(0, 0.25, -1.1)
	torsoAtt.Parent = k.torso
	k.holdTorsoAtt = torsoAtt

	local ballAtt = Instance.new("Attachment")
	ballAtt.Name = "GK_HoldBallAtt"
	ballAtt.Parent = self._ball
	k.holdBallAtt = ballAtt

	local ap = Instance.new("AlignPosition")
	ap.Name = "GK_BallHoldAlignPosition"
	ap.Attachment0 = ballAtt
	ap.Attachment1 = torsoAtt
	ap.MaxForce = 2e6
	ap.MaxVelocity = 200
	ap.Responsiveness = 80
	ap.RigidityEnabled = true
	ap.Parent = self._ball
	k.holdAlignPos = ap

	local ao = Instance.new("AlignOrientation")
	ao.Name = "GK_BallHoldAlignOrientation"
	ao.Attachment0 = ballAtt
	ao.Attachment1 = torsoAtt
	ao.MaxTorque = 1e7
	ao.Responsiveness = 80
	ao.RigidityEnabled = true
	ao.Parent = self._ball
	k.holdAlignOri = ao

	k.throwAt = os.clock() + randRange(self._cfg.holdMin, self._cfg.holdMax)
end

function GoalkeeperAI:_releaseBall(k: Keeper)
	destroyIf(k.holdAlignOri); k.holdAlignOri = nil
	destroyIf(k.holdAlignPos); k.holdAlignPos = nil
	destroyIf(k.holdBallAtt);  k.holdBallAtt = nil
	destroyIf(k.holdTorsoAtt); k.holdTorsoAtt = nil

	k.holding = false
	k.throwAt = nil

	self._ball.CanCollide = true
	self._setBallHeld(false, nil)
	self._ball:SetAttribute("HeldByGK", false)
	self._ball:SetAttribute("HeldByGKTeam", nil)
end

function GoalkeeperAI:_findClosestTeammate(teamKey: string, fromPos: Vector3): BasePart?
	local bestHRP: BasePart? = nil
	local bestD = math.huge

	for _, plr in ipairs(self._getTeamPlayers(teamKey)) do
		local char = plr.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hum and hum.Health > 0 and hrp then
			local d = (hrp.Position - fromPos).Magnitude
			if d < bestD then
				bestD = d
				bestHRP = hrp
			end
		end
	end

	return bestHRP
end

function GoalkeeperAI:_computeLobVelocity(startPos: Vector3, targetPos: Vector3): Vector3
	local g = workspace.Gravity
	local delta = targetPos - startPos
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local dist = flat.Magnitude

	if dist < 1e-3 then
		return Vector3.new(0, 25, 0)
	end

	local desiredHorizSpeed: number
	if dist < 25 then
		desiredHorizSpeed = self._cfg.lobMinPower
	elseif dist < 60 then
		desiredHorizSpeed = (self._cfg.lobMinPower + self._cfg.lobMaxPower) * 0.5
	else
		desiredHorizSpeed = self._cfg.lobMaxPower
	end

	local arcH = self._cfg.lobArcHeight * clamp(dist / 60, 0.7, 1.6)
	local tArc = 2 * math.sqrt((2 * arcH) / g)
	local tSpeed = dist / desiredHorizSpeed
	local t = math.max(tArc, tSpeed)

	local v = (delta + Vector3.new(0, 0.5 * g * t * t, 0)) / t
	v *= (1 + randRange(-self._cfg.lobPowerRand, self._cfg.lobPowerRand))

	local dir = safeUnit(flat, Vector3.new(1, 0, 0))
	local perp = Vector3.new(-dir.Z, 0, dir.X)
	v += perp * (desiredHorizSpeed * randRange(-self._cfg.lobDirRand, self._cfg.lobDirRand))

	return v
end

function GoalkeeperAI:_distributeBall(k: Keeper)
	if not k.holding then return end
	local ball = self._ball
	if not ball then return end

	local closest = self:_findClosestTeammate(k.teamKey, k.hrp.Position)

	local targetPos: Vector3
	if closest then
		targetPos = closest.Position
	else
		local _, forwardSign = self:_goalParams(k.teamKey)
		targetPos = k.hrp.Position + Vector3.new(forwardSign * 55, 14, 0) + Vector3.new(0, 0, math.random(-20, 20))
	end

	self:_releaseBall(k)
	ball.CanCollide = false

	task.defer(function()
		if ball and ball.Parent then
			ball.AssemblyLinearVelocity = self:_computeLobVelocity(ball.Position, targetPos)
			task.delay(0.25, function()
				if ball and ball.Parent then
					ball.CanCollide = true
				end
			end)
		end
	end)
end

function GoalkeeperAI:_dashLaterally(k: Keeper, zTarget: number)
	local now = os.clock()
	if now < k.dashCdUntil then return end
	k.dashCdUntil = now + self._cfg.dashCooldown

	local dz = zTarget - k.hrp.Position.Z
	local dirZ = (dz >= 0) and 1 or -1

	local att = Instance.new("Attachment")
	att.Name = "GK_DashAtt"
	att.Parent = k.hrp

	local lv = Instance.new("LinearVelocity")
	lv.Name = "GK_DashLV"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = 2e5
	lv.VectorVelocity = Vector3.new(0, 0, dirZ * self._cfg.dashSpeed)
	lv.Parent = k.hrp

	task.delay(self._cfg.dashDuration, function()
		destroyIf(lv)
		destroyIf(att)
	end)
end

function GoalkeeperAI:_tryJump(k: Keeper)
	local now = os.clock()
	if now < k.jumpCdUntil then return end

	local grounded = (k.hum.FloorMaterial ~= Enum.Material.Air) and (k.hrp.Position.Y <= k.groundY + 1.15)
	if not grounded then return end

	k.jumpCdUntil = now + self._cfg.jumpCooldown
	k.jumpAirUntil = now + self._cfg.jumpAirControlTime

	k.hum.JumpPower = self._cfg.jumpPower
	k.hum.Jump = true
	k.hum:ChangeState(Enum.HumanoidStateType.Jumping)

	local v = k.hrp.AssemblyLinearVelocity
	if v.Y < self._cfg.jumpBoostVel then
		k.hrp.AssemblyLinearVelocity = Vector3.new(v.X, self._cfg.jumpBoostVel, v.Z)
	end
end

function GoalkeeperAI:_diveAt(k: Keeper, zTarget: number)
	self:_dashLaterally(k, zTarget)
	self:_tryJump(k)
end

function GoalkeeperAI:_punchBall(k: Keeper)
	self:_clearGuidanceForBall()
	self._markLastTouch(k.teamKey, nil)

	local _, forwardSign = self:_goalParams(k.teamKey)
	local ballPos = self._ball.Position
	local side = clamp(ballPos.Z / 30, -1, 1)
	local clearDir = safeUnit(Vector3.new(forwardSign, 0, side * 0.9), Vector3.new(forwardSign, 0, 0))
	local v = clearDir * self._cfg.punchSpeed + Vector3.new(0, self._cfg.punchUp, 0)

	v *= (1 + randRange(-0.06, 0.06))

	self._ball.AssemblyLinearVelocity = v
	self._ball.AssemblyAngularVelocity = Vector3.new(math.rad(80), math.rad(30) * forwardSign, 0)
end

function GoalkeeperAI:_stepKeeper(k: Keeper, _dt: number)
	if not k.model.Parent then return end

	if self._isBallLocked() then
		self:_setKeeperTarget(k, self:_desiredPosition(k), true)
		self:_faceBall(k)
		return
	end

	local ball = self._ball
	if not ball.Parent then return end

	local now = os.clock()
	if now >= k.nextPredictT then
		k.nextPredictT = now + self._cfg.predictInterval
		self:_updatePrediction(k, now)
	end

	self:_faceBall(k)

	if k.holding then
		local goalX, forwardSign = self:_goalParams(k.teamKey)
		local holdPos = Vector3.new(goalX + forwardSign * 5, k.groundY, 0)
		self:_setKeeperTarget(k, holdPos, true)
		k.alignOri.CFrame = CFrame.lookAt(k.hrp.Position, Vector3.new(0, k.groundY, 0))

		if k.throwAt and now >= k.throwAt then
			self:_distributeBall(k)
		end
		return
	end

	do
		local goalX = self:_goalParams(k.teamKey)
		local goalPos = Vector3.new(goalX, k.groundY, 0)
		local nearestToGoal = nearestPlayerDist(goalPos)

		local ballPos = ball.Position
		local speed = ball.AssemblyLinearVelocity.Magnitude
		local distNow = (ballPos - k.hrp.Position).Magnitude

		if nearestToGoal > 20 and speed < 5 and distNow < 25 then
			self:_setKeeperTarget(k, Vector3.new(ballPos.X, k.groundY, ballPos.Z), false)
			local relY = ballPos.Y - k.groundY
			if self:_ballDistToSaveBox(k) <= (self._cfg.catchRange + 1.5) and relY <= self._cfg.catchMaxHeight then
				self:_holdBall(k)
			end
			return
		end
	end

	self:_setKeeperTarget(k, self:_desiredPosition(k), false)

	local pred = k.pred
	if pred.valid and pred.tImpact <= self._cfg.threatTime then
		if not k.reactAt then
			k.reactAt = now + randRange(self._cfg.reactionTimeMin, self._cfg.reactionTimeMax)
			k.reactPoint = pred.point
		end
	else
		k.reactAt = nil
		k.reactPoint = nil
	end

	do
		local goalX, forwardSign = self:_goalParams(k.teamKey)
		local ballPos = ball.Position
		local depth = (ballPos.X - goalX) * forwardSign
		local speed = ball.AssemblyLinearVelocity.Magnitude
		local relY = ballPos.Y - k.groundY

		if depth > 0 and depth < 18 and speed < 10 then
			local dist = self:_ballDistToSaveBox(k)
			if dist <= self._cfg.catchRange + 1.5 and relY <= self._cfg.catchMaxHeight then
				self:_holdBall(k)
				return
			end
		end
	end

	if k.reactAt and now >= k.reactAt and k.reactPoint then
		local goalX, forwardSign = self:_goalParams(k.teamKey)
		local interceptX = goalX + forwardSign * self._cfg.neutralDepth
		local intercept = Vector3.new(interceptX, k.groundY, k.reactPoint.Z)
		local lateralMiss = math.abs(intercept.Z - k.hrp.Position.Z)
		local predRelY = pred.point.Y - k.groundY

		if pred.valid
			and pred.tImpact <= self._cfg.dashTriggerTime
			and lateralMiss >= self._cfg.dashTriggerDist
			and lateralMiss <= self._cfg.dashMaxDist
		then
			self:_diveAt(k, intercept.Z)
		elseif pred.valid
			and predRelY >= self._cfg.normalReachHeight
			and pred.tImpact <= (self._cfg.jumpLeadTime + self._cfg.jumpLeadExtra)
		then
			self:_tryJump(k)
		end

		local ballPos = ball.Position
		local relY = ballPos.Y - k.groundY
		local speed = ball.AssemblyLinearVelocity.Magnitude
		local distNow = self:_ballDistToSaveBox(k)

		local isHighBall = relY > self._cfg.catchMaxHeight
		local punchRange = self._cfg.punchRange + (isHighBall and self._cfg.aerialSaveExtraRange or 0)

		if distNow <= self._cfg.saveRange then
			if distNow <= self._cfg.catchRange
				and speed <= self._cfg.catchMaxBallSpeed
				and relY <= self._cfg.catchMaxHeight
			then
				self:_holdBall(k)
				return
			end

			if isHighBall and pred.valid and pred.tImpact <= (self._cfg.jumpLeadTime + self._cfg.jumpLeadExtra) then
				self:_tryJump(k)
			end

			if distNow <= punchRange and relY <= self._cfg.punchMaxHeight then
				self:_punchBall(k)
				return
			end
		end
	end
end

function GoalkeeperAI:Step(dt: number)
	self:_refreshKeeper("Home")
	self:_refreshKeeper("Away")

	for _, teamKey in ipairs({ "Home", "Away" }) do
		local k = self._keepers[teamKey]
		if k then
			self:_stepKeeper(k, dt)
		end
	end
end

return GoalkeeperAI