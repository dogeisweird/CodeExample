--!strict
-- GoalkeeperAI.lua

local Players = game:GetService("Players")

local Constants = {
	ALIGN_MAX_FORCE    = 1e6,
	ALIGN_MAX_TORQUE   = 1e7,
	HOLD_MAX_FORCE     = 2e6,
	HOLD_VELOCITY      = 200,
	DASH_MAX_FORCE     = 2e5,

	SAFE_RUSH_DIST        = 20,
	LOOSE_BALL_SPEED      = 5,
	LOOSE_BALL_DIST       = 25,
	BOX_DEPTH             = 18,
	CATCH_FUDGE_RANGE     = 1.5,
	AIRBORNE_GROUND_OFFSET = 0.9,
	JUMP_FALL_TOLERANCE   = 1.15,

	PUNCH_SPIN_X = 80,
	PUNCH_SPIN_Y = 30,

	LOB_MIN_DIST = 6,
}

export type AIConfig = {
	reactionTimeMin: number,
	reactionTimeMax: number,
	predictInterval: number,
	predictHorizon: number,

	positioningSpeed: number,
	positioningResponsiveness: number,
	neutralDepth: number,
	stepOutDepth: number,
	farDistance: number,
	goalSideMargin: number,
	penaltyDepth: number,
	penaltyHalfWidth: number,

	threatTime: number,
	saveRange: number,
	catchRange: number,
	catchMaxBallSpeed: number,
	catchMaxHeight: number,
	punchRange: number,
	punchMaxHeight: number,
	punchSpeed: number,
	punchUp: number,

	saveHitboxSize: Vector3,
	saveHitboxOffset: Vector3,
	aerialSaveExtraRange: number,
	jumpLeadExtra: number,

	jumpPower: number,
	jumpBoostVel: number,
	jumpAirControlTime: number,
	normalReachHeight: number,
	jumpLeadTime: number,
	jumpCooldown: number,

	dashSpeed: number,
	dashDuration: number,
	dashCooldown: number,
	dashTriggerTime: number,
	dashTriggerDist: number,
	dashMaxDist: number,

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
	timeToImpact: number,
	point: Vector3,
	speed: number,
}

type Keeper = {
	teamKey: string,
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	torso: BasePart,
	groundY: number,

	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	rootAttachment: Attachment,

	holdTorsoAttachment: Attachment?,
	holdBallAttachment: Attachment?,
	holdAlignPosition: AlignPosition?,
	holdAlignOrientation: AlignOrientation?,

	nextPredictTime: number,
	prediction: Prediction,

	reactAt: number?,
	reactPoint: Vector3?,

	jumpCooldownUntil: number,
	jumpAirUntil: number,
	dashCooldownUntil: number,

	holding: boolean,
	throwAt: number?,
}

local DEFAULT: AIConfig = {
	reactionTimeMin = 0.15,
	reactionTimeMax = 0.35,
	predictInterval = 0.12,
	predictHorizon = 2.2,

	positioningSpeed = 22,
	positioningResponsiveness = 35,
	neutralDepth = 4.0,
	stepOutDepth = 5.5,
	farDistance = 140,
	goalSideMargin = 1.5,
	penaltyDepth = 70,
	penaltyHalfWidth = 70,

	threatTime = 1.25,
	saveRange = 10,
	catchRange = 6.5,
	catchMaxBallSpeed = 58,
	catchMaxHeight = 6.2,
	punchRange = 9.5,
	punchMaxHeight = 10.5,
	punchSpeed = 95,
	punchUp = 18,

	saveHitboxSize = Vector3.new(5.2, 6.8, 6.0),
	saveHitboxOffset = Vector3.new(0, 1.35, 0),
	aerialSaveExtraRange = 2.25,
	jumpLeadExtra = 0.28,

	jumpPower = 62,
	jumpBoostVel = 16,
	jumpAirControlTime = 0.22,
	normalReachHeight = 5.4,
	jumpLeadTime = 0.42,
	jumpCooldown = 0.9,

	dashSpeed = 85,
	dashDuration = 0.18,
	dashCooldown = 1.1,
	dashTriggerTime = 0.55,
	dashTriggerDist = 4.5,
	dashMaxDist = 15,

	holdMin = 0.5,
	holdMax = 1.2,
	lobMinPower = 38,
	lobMaxPower = 78,
	lobArcHeight = 16,
	lobPowerRand = 0.05,
	lobDirRand = 0.06,
}

local function clamp(n: number, min: number, max: number): number
	return math.max(min, math.min(max, n))
end

local function randRange(min: number, max: number): number
	return min + (max - min) * math.random()
end

local function safeUnit(v: Vector3, fallback: Vector3): Vector3
	return v.Magnitude > 1e-4 and v.Unit or fallback
end

local function destroyIf(inst: Instance?)
	if inst and inst.Parent then
		inst:Destroy()
	end
end

local function getNearestPlayerDistance(pos: Vector3): number
	local minDist = math.huge
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if humanoid and humanoid.Health > 0 and root then
			local d = (root.Position - pos).Magnitude
			if d < minDist then
				minDist = d
			end
		end
	end
	return minDist
end

local function createBodyPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, canCollide: boolean, transparency: number?): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = canCollide
	part.Transparency = transparency or 0
	part.Parent = parent
	return part
end

local function createMotor(part0: BasePart, part1: BasePart, name: string, c0: CFrame, c1: CFrame)
	local motor = Instance.new("Motor6D")
	motor.Name = name
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = c0
	motor.C1 = c1
	motor.Parent = part0
	return motor
end

local function buildR6Goalkeeper(teamKey: string, spawnCF: CFrame, teamColor: Color3, jumpPower: number): (Model, Humanoid, BasePart, BasePart)
	local model = Instance.new("Model")
	model.Name = teamKey .. "_GoalkeeperNPC"

	local rootPart = createBodyPart(model, "HumanoidRootPart", Vector3.new(2, 2, 1), spawnCF, Color3.new(1, 1, 1), false, 1)
	rootPart.CanQuery = false

	local torso    = createBodyPart(model, "Torso",     Vector3.new(2, 2, 1), spawnCF,                      teamColor,                     true)
	local head     = createBodyPart(model, "Head",      Vector3.new(2, 1, 1), spawnCF * CFrame.new(0, 1.5, 0),  Color3.new(1, 0.85, 0.75),    true)
	local leftArm  = createBodyPart(model, "Left Arm",  Vector3.new(1, 2, 1), spawnCF * CFrame.new(-1.5, 0, 0), teamColor,                     true)
	local rightArm = createBodyPart(model, "Right Arm", Vector3.new(1, 2, 1), spawnCF * CFrame.new(1.5, 0, 0),  teamColor,                     true)
	local leftLeg  = createBodyPart(model, "Left Leg",  Vector3.new(1, 2, 1), spawnCF * CFrame.new(-0.5, -2, 0), Color3.new(0.15, 0.15, 0.15), true)
	local rightLeg = createBodyPart(model, "Right Leg", Vector3.new(1, 2, 1), spawnCF * CFrame.new(0.5, -2, 0),  Color3.new(0.15, 0.15, 0.15), true)

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.AutoRotate = false
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = jumpPower
	humanoid.Parent = model

	createMotor(rootPart, torso,     "RootJoint",     CFrame.new(),           CFrame.new())
	createMotor(torso,    head,      "Neck",          CFrame.new(0, 1, 0),    CFrame.new(0, -0.5, 0))
	createMotor(torso,    leftArm,   "Left Shoulder", CFrame.new(-1, 0.5, 0), CFrame.new(0.5, 0.5, 0))
	createMotor(torso,    rightArm,  "Right Shoulder",CFrame.new(1, 0.5, 0),  CFrame.new(-0.5, 0.5, 0))
	createMotor(torso,    leftLeg,   "Left Hip",      CFrame.new(-0.5, -1, 0),CFrame.new(0, 1, 0))
	createMotor(torso,    rightLeg,  "Right Hip",     CFrame.new(0.5, -1, 0), CFrame.new(0, 1, 0))

	local face = Instance.new("Decal")
	face.Name = "face"
	face.Texture = "rbxasset://textures/face.png"
	face.Parent = head

	model.PrimaryPart = rootPart
	model.Parent = workspace
	model:PivotTo(spawnCF)

	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc:SetNetworkOwner(nil)
		end
	end

	return model, humanoid, rootPart, torso
end

local GoalkeeperAI = {}
GoalkeeperAI.__index = GoalkeeperAI

function GoalkeeperAI.new(deps: Deps)
	assert(deps and deps.ball and deps.gameConfig, "GoalkeeperAI.new requires ball + gameConfig")
	assert(typeof(deps.getGKOccupied) == "function", "GoalkeeperAI.new requires getGKOccupied(teamKey)")
	assert(typeof(deps.getTeamPlayers) == "function", "GoalkeeperAI.new requires getTeamPlayers(teamKey)")

	local self = setmetatable({}, GoalkeeperAI)
	self._ball = deps.ball
	self._game = deps.gameConfig

	self._cfg = table.clone(DEFAULT)
	if deps.aiConfig then
		for key, value in pairs(deps.aiConfig :: any) do
			(self._cfg :: any)[key] = value
		end
	end

	self._getGKOccupied = deps.getGKOccupied
	self._getTeamPlayers = deps.getTeamPlayers
	self._setBallHeld  = deps.setBallHeld  or function() end
	self._markLastTouch = deps.markLastTouch or function() end
	self._isBallLocked = deps.isBallLocked  or function() return false end

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
	local keeper = self._keepers[teamKey]
	if not keeper then return end

	if keeper.holding then
		self:_releaseBall(keeper)
	end

	if keeper.model and keeper.model.Parent then
		keeper.model:Destroy()
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

	local halfLength = self._game.FieldLength / 2
	local goalX = (teamKey == "Home") and -halfLength or halfLength
	local forwardSign = (teamKey == "Home") and 1 or -1

	local spawnCF = CFrame.lookAt(
		Vector3.new(goalX + forwardSign * (self._cfg.neutralDepth + 1), spawnPos.Y, spawnPos.Z),
		Vector3.new(goalX + forwardSign * 40, spawnPos.Y, 0)
	)

	local teamColor: Color3 = self._game.Teams[teamKey].Color3
	local model, humanoid, rootPart, torso = buildR6Goalkeeper(teamKey, spawnCF, teamColor, self._cfg.jumpPower)

	local rootAttachment = Instance.new("Attachment")
	rootAttachment.Name = "GK_RootAtt"
	rootAttachment.Parent = rootPart

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "GK_AlignPosition"
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = rootAttachment
	alignPosition.MaxForce = Constants.ALIGN_MAX_FORCE
	alignPosition.MaxVelocity = self._cfg.positioningSpeed
	alignPosition.Responsiveness = self._cfg.positioningResponsiveness
	alignPosition.RigidityEnabled = false
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.Parent = rootPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "GK_AlignOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = rootAttachment
	alignOrientation.MaxTorque = Constants.ALIGN_MAX_TORQUE
	alignOrientation.Responsiveness = 30
	alignOrientation.PrimaryAxisOnly = false
	alignOrientation.Parent = rootPart

	local keeper: Keeper = {
		teamKey = teamKey,
		model = model,
		humanoid = humanoid,
		rootPart = rootPart,
		torso = torso,
		groundY = spawnPos.Y,

		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		rootAttachment = rootAttachment,

		nextPredictTime = 0,
		prediction = { valid = false, timeToImpact = 0, point = Vector3.zero, speed = 0 },

		jumpCooldownUntil = 0,
		jumpAirUntil = 0,
		dashCooldownUntil = 0,

		holding = false,
	}

	self._keepers[teamKey] = keeper
end

-- returns goalX, forwardSign, goalCenter
function GoalkeeperAI:_goalParams(teamKey: string): (number, number, Vector3)
	local halfLength = self._game.FieldLength / 2
	local goalX = (teamKey == "Home") and -halfLength or halfLength
	local forwardSign = (teamKey == "Home") and 1 or -1
	local goalCenter = Vector3.new(goalX, 0, 0)
	return goalX, forwardSign, goalCenter
end

function GoalkeeperAI:_updatePrediction(keeper: Keeper, _now: number)
	local ball = self._ball
	local pos = ball.Position
	local vel = ball.AssemblyLinearVelocity
	local speed = vel.Magnitude
	local gravity = workspace.Gravity

	local goalX, forwardSign = self:_goalParams(keeper.teamKey)
	local keeperX = goalX + forwardSign * self._cfg.neutralDepth

	-- ball moving away or lateral-only, nothing to predict
	if math.abs(vel.X) < 1 or (goalX - pos.X) * vel.X <= 0 then
		keeper.prediction = { valid = false, timeToImpact = 0, point = Vector3.zero, speed = speed }
		return
	end

	local timeToGoal   = (goalX   - pos.X) / vel.X
	local timeToKeeper = (keeperX - pos.X) / vel.X

	if timeToGoal <= 0 or timeToKeeper <= 0 or timeToKeeper > self._cfg.predictHorizon then
		keeper.prediction = { valid = false, timeToImpact = 0, point = Vector3.zero, speed = speed }
		return
	end

	local goalY   = pos.Y + vel.Y * timeToGoal   - 0.5 * gravity * timeToGoal   * timeToGoal
	local goalZ   = pos.Z + vel.Z * timeToGoal
	local keeperY = pos.Y + vel.Y * timeToKeeper  - 0.5 * gravity * timeToKeeper * timeToKeeper
	local keeperZ = pos.Z + vel.Z * timeToKeeper

	local goalHit   = Vector3.new(goalX,   goalY,   goalZ)
	local keeperHit = Vector3.new(keeperX, keeperY, keeperZ)

	local goalHalfWidth = self._game.GoalWidth / 2
	local onTarget = math.abs(goalHit.Z) <= (goalHalfWidth + 2)

	keeper.prediction = {
		valid = onTarget and speed > 6,
		timeToImpact = timeToKeeper,
		point = keeperHit,
		speed = speed,
	}
end

function GoalkeeperAI:_desiredPosition(keeper: Keeper): Vector3
	local ballPos = self._ball.Position
	local goalX, forwardSign = self:_goalParams(keeper.teamKey)
	local goalHalfWidth = self._game.GoalWidth / 2

	local depth    = (ballPos.X - goalX) * forwardSign
	local farAlpha = clamp(1 - (depth / self._cfg.farDistance), 0, 1)

	local zTrack = clamp(ballPos.Z, -goalHalfWidth + self._cfg.goalSideMargin, goalHalfWidth - self._cfg.goalSideMargin)
	zTrack *= (0.25 + 0.75 * farAlpha)

	local xPos = goalX + forwardSign * self._cfg.neutralDepth

	if depth > 0 and depth <= self._cfg.penaltyDepth and math.abs(ballPos.Z) <= self._cfg.penaltyHalfWidth then
		local stepAlpha = 1 - (depth / self._cfg.penaltyDepth)
		xPos = goalX + forwardSign * (self._cfg.neutralDepth + self._cfg.stepOutDepth * stepAlpha)
	end

	if depth < -1 then
		xPos = goalX + forwardSign * self._cfg.neutralDepth
		zTrack = 0
	end

	return Vector3.new(xPos, keeper.groundY, zTrack)
end

function GoalkeeperAI:_setKeeperTarget(keeper: Keeper, target: Vector3, stickToGround: boolean)
	local yPos = keeper.groundY
	local now = os.clock()
	local state = keeper.humanoid:GetState()

	local isAirborne = (state == Enum.HumanoidStateType.Jumping)
		or (state == Enum.HumanoidStateType.Freefall)
		or (state == Enum.HumanoidStateType.FallingDown)

	-- let physics handle the drop naturally while airborne
	if not stickToGround and (isAirborne or now < keeper.jumpAirUntil) then
		yPos = math.max(keeper.groundY, keeper.rootPart.Position.Y - Constants.AIRBORNE_GROUND_OFFSET)
	end

	keeper.alignPosition.Position = Vector3.new(target.X, yPos, target.Z)
end

function GoalkeeperAI:_faceBall(keeper: Keeper)
	local pos = keeper.rootPart.Position
	local ballPos = self._ball.Position
	keeper.alignOrientation.CFrame = CFrame.lookAt(pos, Vector3.new(ballPos.X, pos.Y, ballPos.Z))
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

-- OBB distance from ball to the keeper's save box (0 = inside)
function GoalkeeperAI:_ballDistToSaveBox(keeper: Keeper): number
	local torsoCF  = keeper.torso.CFrame
	local ballLocal = torsoCF:PointToObjectSpace(self._ball.Position)

	local center   = self._cfg.saveHitboxOffset
	local halfSize = self._cfg.saveHitboxSize * 0.5
	local rel      = ballLocal - center

	local dx = math.max(math.abs(rel.X) - halfSize.X, 0)
	local dy = math.max(math.abs(rel.Y) - halfSize.Y, 0)
	local dz = math.max(math.abs(rel.Z) - halfSize.Z, 0)

	return math.sqrt(dx*dx + dy*dy + dz*dz)
end

function GoalkeeperAI:_holdBall(keeper: Keeper)
	if keeper.holding or not self._ball.Parent then return end

	self:_clearGuidanceForBall()
	self._markLastTouch(keeper.teamKey, nil)

	self._ball.AssemblyLinearVelocity  = Vector3.zero
	self._ball.AssemblyAngularVelocity = Vector3.zero
	self._ball:SetNetworkOwner(nil)

	keeper.holding = true
	self._ball.CanCollide = false
	self._setBallHeld(true, keeper.teamKey)
	self._ball:SetAttribute("HeldByGK", true)
	self._ball:SetAttribute("HeldByGKTeam", keeper.teamKey)

	local torsoAtt = Instance.new("Attachment")
	torsoAtt.Name = "GK_HoldTorsoAtt"
	torsoAtt.Position = Vector3.new(0, 0.25, -1.1)
	torsoAtt.Parent = keeper.torso
	keeper.holdTorsoAttachment = torsoAtt

	local ballAtt = Instance.new("Attachment")
	ballAtt.Name = "GK_HoldBallAtt"
	ballAtt.Parent = self._ball
	keeper.holdBallAttachment = ballAtt

	local alignPos = Instance.new("AlignPosition")
	alignPos.Name = "GK_BallHoldAlignPosition"
	alignPos.Attachment0 = ballAtt
	alignPos.Attachment1 = torsoAtt
	alignPos.MaxForce = Constants.HOLD_MAX_FORCE
	alignPos.MaxVelocity = Constants.HOLD_VELOCITY
	alignPos.Responsiveness = 80
	alignPos.RigidityEnabled = true
	alignPos.Parent = self._ball
	keeper.holdAlignPosition = alignPos

	local alignOri = Instance.new("AlignOrientation")
	alignOri.Name = "GK_BallHoldAlignOrientation"
	alignOri.Attachment0 = ballAtt
	alignOri.Attachment1 = torsoAtt
	alignOri.MaxTorque = Constants.ALIGN_MAX_TORQUE
	alignOri.Responsiveness = 80
	alignOri.RigidityEnabled = true
	alignOri.Parent = self._ball
	keeper.holdAlignOrientation = alignOri

	keeper.throwAt = os.clock() + randRange(self._cfg.holdMin, self._cfg.holdMax)
end

function GoalkeeperAI:_releaseBall(keeper: Keeper)
	destroyIf(keeper.holdAlignOrientation)
	keeper.holdAlignOrientation = nil
	destroyIf(keeper.holdAlignPosition)
	keeper.holdAlignPosition = nil
	destroyIf(keeper.holdBallAttachment)
	keeper.holdBallAttachment = nil
	destroyIf(keeper.holdTorsoAttachment)
	keeper.holdTorsoAttachment = nil

	keeper.holding = false
	keeper.throwAt = nil

	self._ball.CanCollide = true
	self._setBallHeld(false, nil)
	self._ball:SetAttribute("HeldByGK", false)
	self._ball:SetAttribute("HeldByGKTeam", nil)
end

function GoalkeeperAI:_findClosestTeammate(teamKey: string, fromPos: Vector3): BasePart?
	local bestRoot: BasePart? = nil
	local bestDist = math.huge

	for _, plr in ipairs(self._getTeamPlayers(teamKey)) do
		local char = plr.Character
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if humanoid and humanoid.Health > 0 and root then
			local d = (root.Position - fromPos).Magnitude
			if d < bestDist then
				bestDist = d
				bestRoot = root
			end
		end
	end

	return bestRoot
end

function GoalkeeperAI:_computeLobVelocity(startPos: Vector3, targetPos: Vector3): Vector3
	local gravity = workspace.Gravity
	local delta = targetPos - startPos
	local flatVec = Vector3.new(delta.X, 0, delta.Z)
	local distance = flatVec.Magnitude

	if distance < Constants.LOB_MIN_DIST then
		return Vector3.new(0, 25, 0)
	end

	local desiredSpeed: number
	if distance < 25 then
		desiredSpeed = self._cfg.lobMinPower
	elseif distance < 60 then
		desiredSpeed = (self._cfg.lobMinPower + self._cfg.lobMaxPower) * 0.5
	else
		desiredSpeed = self._cfg.lobMaxPower
	end

	-- scale arc height so short passes don't drill into the ground
	local arcHeight  = self._cfg.lobArcHeight * clamp(distance / 60, 0.7, 1.6)
	local timeArc    = 2 * math.sqrt((2 * arcHeight) / gravity)
	local timeSpeed  = distance / desiredSpeed
	local travelTime = math.max(timeArc, timeSpeed)

	local velocity = (delta + Vector3.new(0, 0.5 * gravity * travelTime * travelTime, 0)) / travelTime

	velocity *= (1 + randRange(-self._cfg.lobPowerRand, self._cfg.lobPowerRand))
	local dir  = safeUnit(flatVec, Vector3.new(1, 0, 0))
	local perp = Vector3.new(-dir.Z, 0, dir.X)
	velocity += perp * (desiredSpeed * randRange(-self._cfg.lobDirRand, self._cfg.lobDirRand))

	return velocity
end

function GoalkeeperAI:_distributeBall(keeper: Keeper)
	if not keeper.holding or not self._ball then return end

	local teammate = self:_findClosestTeammate(keeper.teamKey, keeper.rootPart.Position)
	local targetPos: Vector3

	if teammate then
		targetPos = teammate.Position
	else
		local _, forwardSign = self:_goalParams(keeper.teamKey)
		targetPos = keeper.rootPart.Position
			+ Vector3.new(forwardSign * 55, 14, 0)
			+ Vector3.new(0, 0, math.random(-20, 20))
	end

	self:_releaseBall(keeper)
	self._ball.CanCollide = false

	task.defer(function()
		if self._ball and self._ball.Parent then
			self._ball.AssemblyLinearVelocity = self:_computeLobVelocity(self._ball.Position, targetPos)
			task.delay(0.25, function()
				if self._ball and self._ball.Parent then
					self._ball.CanCollide = true
				end
			end)
		end
	end)
end

function GoalkeeperAI:_dashLaterally(keeper: Keeper, zTarget: number)
	local now = os.clock()
	if now < keeper.dashCooldownUntil then return end

	keeper.dashCooldownUntil = now + self._cfg.dashCooldown
	local dirZ = (zTarget - keeper.rootPart.Position.Z >= 0) and 1 or -1

	local dashAtt = Instance.new("Attachment")
	dashAtt.Name = "GK_DashAtt"
	dashAtt.Parent = keeper.rootPart

	local lv = Instance.new("LinearVelocity")
	lv.Name = "GK_DashLV"
	lv.Attachment0 = dashAtt
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = Constants.DASH_MAX_FORCE
	lv.VectorVelocity = Vector3.new(0, 0, dirZ * self._cfg.dashSpeed)
	lv.Parent = keeper.rootPart

	task.delay(self._cfg.dashDuration, function()
		destroyIf(lv)
		destroyIf(dashAtt)
	end)
end

function GoalkeeperAI:_tryJump(keeper: Keeper)
	local now = os.clock()
	if now < keeper.jumpCooldownUntil then return end

	local grounded = (keeper.humanoid.FloorMaterial ~= Enum.Material.Air)
		and (keeper.rootPart.Position.Y <= keeper.groundY + Constants.JUMP_FALL_TOLERANCE)
	if not grounded then return end

	keeper.jumpCooldownUntil = now + self._cfg.jumpCooldown
	keeper.jumpAirUntil      = now + self._cfg.jumpAirControlTime

	keeper.humanoid.JumpPower = self._cfg.jumpPower
	keeper.humanoid.Jump = true
	keeper.humanoid:ChangeState(Enum.HumanoidStateType.Jumping)

	local vel = keeper.rootPart.AssemblyLinearVelocity
	if vel.Y < self._cfg.jumpBoostVel then
		keeper.rootPart.AssemblyLinearVelocity = Vector3.new(vel.X, self._cfg.jumpBoostVel, vel.Z)
	end
end

function GoalkeeperAI:_diveAt(keeper: Keeper, zTarget: number)
	self:_dashLaterally(keeper, zTarget)
	self:_tryJump(keeper)
end

function GoalkeeperAI:_punchBall(keeper: Keeper)
	self:_clearGuidanceForBall()
	self._markLastTouch(keeper.teamKey, nil)

	local _, forwardSign = self:_goalParams(keeper.teamKey)
	local ballPos = self._ball.Position

	-- bias the clear toward whichever side the ball is on rather than straight up the middle
	local sideAlpha = clamp(ballPos.Z / 30, -1, 1)
	local clearDir  = safeUnit(Vector3.new(forwardSign, 0, sideAlpha * 0.9), Vector3.new(forwardSign, 0, 0))
	local velocity  = clearDir * self._cfg.punchSpeed + Vector3.new(0, self._cfg.punchUp, 0)

	velocity *= (1 + randRange(-0.06, 0.06))

	self._ball.AssemblyLinearVelocity  = velocity
	self._ball.AssemblyAngularVelocity = Vector3.new(
		math.rad(Constants.PUNCH_SPIN_X),
		math.rad(Constants.PUNCH_SPIN_Y) * forwardSign,
		0
	)
end

function GoalkeeperAI:_stepKeeper(keeper: Keeper, _dt: number)
	if not keeper.model.Parent then return end
	local now = os.clock()

	if self._isBallLocked() then
		self:_setKeeperTarget(keeper, self:_desiredPosition(keeper), true)
		self:_faceBall(keeper)
		return
	end

	local ball = self._ball
	if not ball.Parent then return end

	if now >= keeper.nextPredictTime then
		keeper.nextPredictTime = now + self._cfg.predictInterval
		self:_updatePrediction(keeper, now)
	end

	self:_faceBall(keeper)

	if keeper.holding then
		local goalX, forwardSign = self:_goalParams(keeper.teamKey)
		local holdPos = Vector3.new(goalX + forwardSign * 5, keeper.groundY, 0)
		self:_setKeeperTarget(keeper, holdPos, true)
		keeper.alignOrientation.CFrame = CFrame.lookAt(keeper.rootPart.Position, Vector3.new(0, keeper.groundY, 0))

		if keeper.throwAt and now >= keeper.throwAt then
			self:_distributeBall(keeper)
		end
		return
	end

	local goalX = self:_goalParams(keeper.teamKey)
	local goalPos = Vector3.new(goalX, keeper.groundY, 0)
	local nearestEnemyDist = getNearestPlayerDistance(goalPos)

	local ballPos   = ball.Position
	local ballSpeed = ball.AssemblyLinearVelocity.Magnitude
	local ballDist  = (ballPos - keeper.rootPart.Position).Magnitude

	local safeToRush = nearestEnemyDist > Constants.SAFE_RUSH_DIST
		and ballSpeed < Constants.LOOSE_BALL_SPEED
		and ballDist  < Constants.LOOSE_BALL_DIST

	if safeToRush then
		self:_setKeeperTarget(keeper, Vector3.new(ballPos.X, keeper.groundY, ballPos.Z), false)
		local relY = ballPos.Y - keeper.groundY
		if self:_ballDistToSaveBox(keeper) <= (self._cfg.catchRange + Constants.CATCH_FUDGE_RANGE) and relY <= self._cfg.catchMaxHeight then
			self:_holdBall(keeper)
		end
		return
	end

	self:_setKeeperTarget(keeper, self:_desiredPosition(keeper), false)

	local prediction = keeper.prediction
	if prediction.valid and prediction.timeToImpact <= self._cfg.threatTime then
		if not keeper.reactAt then
			keeper.reactAt   = now + randRange(self._cfg.reactionTimeMin, self._cfg.reactionTimeMax)
			keeper.reactPoint = prediction.point
		end
	else
		keeper.reactAt    = nil
		keeper.reactPoint = nil
	end

	-- scoop slow balls that roll inside the box without waiting for the reaction delay
	local _, forwardSign = self:_goalParams(keeper.teamKey)
	local depth = (ballPos.X - goalX) * forwardSign
	if depth > 0 and depth < Constants.BOX_DEPTH and ballSpeed < 10 then
		local relY = ballPos.Y - keeper.groundY
		if self:_ballDistToSaveBox(keeper) <= self._cfg.catchRange + Constants.CATCH_FUDGE_RANGE and relY <= self._cfg.catchMaxHeight then
			self:_holdBall(keeper)
			return
		end
	end

	if not (keeper.reactAt and now >= keeper.reactAt and keeper.reactPoint) then return end

	local interceptX = goalX + forwardSign * self._cfg.neutralDepth
	local intercept  = Vector3.new(interceptX, keeper.groundY, keeper.reactPoint.Z)
	local lateralMiss = math.abs(intercept.Z - keeper.rootPart.Position.Z)
	local predRelY    = prediction.point.Y - keeper.groundY

	local needsDive = prediction.valid
		and prediction.timeToImpact <= self._cfg.dashTriggerTime
		and lateralMiss >= self._cfg.dashTriggerDist
		and lateralMiss <= self._cfg.dashMaxDist

	if needsDive then
		self:_diveAt(keeper, intercept.Z)
	elseif prediction.valid and predRelY >= self._cfg.normalReachHeight and prediction.timeToImpact <= (self._cfg.jumpLeadTime + self._cfg.jumpLeadExtra) then
		self:_tryJump(keeper)
	end

	local relY      = ballPos.Y - keeper.groundY
	local isHighBall = relY > self._cfg.catchMaxHeight
	local punchRange = self._cfg.punchRange + (isHighBall and self._cfg.aerialSaveExtraRange or 0)
	local boxDist    = self:_ballDistToSaveBox(keeper)

	if boxDist > self._cfg.saveRange then return end

	local canCatch = boxDist <= self._cfg.catchRange and ballSpeed <= self._cfg.catchMaxBallSpeed and relY <= self._cfg.catchMaxHeight
	if canCatch then
		self:_holdBall(keeper)
		return
	end

	if isHighBall and prediction.valid and prediction.timeToImpact <= (self._cfg.jumpLeadTime + self._cfg.jumpLeadExtra) then
		self:_tryJump(keeper)
	end

	if boxDist <= punchRange and relY <= self._cfg.punchMaxHeight then
		self:_punchBall(keeper)
	end
end

function GoalkeeperAI:Step(dt: number)
	self:_refreshKeeper("Home")
	self:_refreshKeeper("Away")

	for _, teamKey in ipairs({ "Home", "Away" }) do
		local keeper = self._keepers[teamKey]
		if keeper then
			self:_stepKeeper(keeper, dt)
		end
	end
end

return GoalkeeperAI
