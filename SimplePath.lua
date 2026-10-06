--[[
    ---------------------------------------------------------------------

    SimplePath — Optimized Build

    Original:
    Created by: @V3N0M_Z
    Reference: https://v3n0m-z.github.io/RBLX-SimplePath/

    Optimized / Maintained by:
    @sqw1zo_official
    GitHub: https://github.com/MaTix6666/SimplePath-Optimized

    License: MIT

    ---------------------------------------------------------------------

    Optimized build. Public API is identical to the original SimplePath:
    Path.new, Path:Run, Path:Stop, Path:Destroy, Path.GetNearestCharacter,
    events Reached / WaypointReached / Blocked / Error / Stopped
    (:Connect/:Once/:Wait),

    Path.Status, Path.LastError, Path.Visualize.

    ---------------------------------------------------------------------
]]

local DEFAULT_SETTINGS = {

	TIME_VARIANCE = 0.07;

	COMPARISON_CHECKS = 1;

	JUMP_WHEN_STUCK = true;
}

---------------------------------------------------------------------

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")

--[[ SIGNAL ]]--
--Lightweight pure-Lua replacement for BindableEvent.
--Mimics BindableEvent semantics: handlers run in their own thread (errors/yields in a
--handler never break the library) and are deferred (workspace.SignalBehavior = Deferred).
--Handler table is created lazily, so an unused signal costs a single table.
local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then return end
	self.Connected = false
	local handlers = self._signal._handlers
	if handlers then
		local i = table.find(handlers, self)
		if i then
			table.remove(handlers, i)
		end
	end
end

local Signal = {}
Signal.__index = Signal

function Signal.new()
	local signal = setmetatable({ _handlers = false }, Signal)
	signal.Event = signal
	return signal
end

function Signal:Connect(fn)
	local handlers = self._handlers
	if not handlers then
		handlers = {}
		self._handlers = handlers
	end
	local connection = setmetatable({ Connected = true, _fn = fn, _signal = self }, Connection)
	handlers[#handlers + 1] = connection
	return connection
end

function Signal:Once(fn)
	local connection = self:Connect(fn)
	connection._once = true
	return connection
end

function Signal:Wait()
	local connection = self:Connect(coroutine.running())
	connection._once = true
	connection._thread = true
	return coroutine.yield()
end

local function dispatch(connection, ...)
	if not connection.Connected then return end
	if connection._once then
		connection:Disconnect()
	end
	if connection._thread then
		task.spawn(connection._fn, ...) --_fn is a thread here
	else
		connection._fn(...)
	end
end

function Signal:Fire(...)
	local handlers = self._handlers
	if not handlers then return end
	--dispatch is deferred, so no user code can connect/disconnect during scheduling;
	--iterating the live table is safe and avoids a table.clone on every fire
	for i = #handlers, 1, -1 do
		task.defer(dispatch, handlers[i], ...)
	end
end

function Signal:Destroy()
	local handlers = self._handlers
	if handlers then
		for i = 1, #handlers do
			handlers[i].Connected = false
		end
		table.clear(handlers)
	end
end

--[[ PATH ]]--
local function output(func, msg)
	func(((func == error and "SimplePath Error: ") or "SimplePath: ")..msg)
end

local function warnTraceback(msg)
	warn(debug.traceback(msg))
end

local Path = {
	StatusType = {
		Idle = "Idle";
		Active = "Active";
	};
	ErrorType = {
		LimitReached = "LimitReached";
		TargetUnreachable = "TargetUnreachable";
		ComputationError = "ComputationError";
		AgentStuck = "AgentStuck";
	};
}

--Events, Status, LastError and Visualize are plain fields on the object, so __index can be the
--Path table itself (fast path). Only a missing key reaches the fallback below, which keeps the
--original error when Path.Stopped is used on a non-humanoid.
Path.__index = Path
setmetatable(Path, {
	__index = function(_, index)
		if index == "Stopped" then
			output(error, "Attempt to use Path.Stopped on a non-humanoid.")
		end
		return nil
	end;
})

local STATUS_IDLE = Path.StatusType.Idle
local STATUS_ACTIVE = Path.StatusType.Active
local JUMP = Enum.PathWaypointAction.Jump
local NO_PATH = Enum.PathStatus.NoPath
local STATE_JUMPING = Enum.HumanoidStateType.Jumping
local STATE_FREEFALL = Enum.HumanoidStateType.Freefall

--Used to visualize waypoints
local visualWaypoint = Instance.new("Part")
visualWaypoint.Size = Vector3.new(0.3, 0.3, 0.3)
visualWaypoint.Anchored = true
visualWaypoint.CanCollide = false
visualWaypoint.CanTouch = false
visualWaypoint.CanQuery = false
visualWaypoint.CastShadow = false
visualWaypoint.Material = Enum.Material.Neon
visualWaypoint.Shape = Enum.PartType.Ball

local COLOR_END = Color3.fromRGB(0, 255, 0)
local COLOR_JUMP = Color3.fromRGB(255, 0, 0)
local COLOR_WALK = Color3.fromRGB(255, 139, 0)

--[[ PRIVATE FUNCTIONS ]]--
local function declareError(self, errorType)
	self.LastError = errorType
	self.Error:Fire(errorType)
end

--Create visual waypoints (properties are set before parenting to avoid replicating changes)
local function createVisualWaypoints(waypoints: {PathWaypoint})
	local count = #waypoints
	local visualWaypoints = table.create(count)
	for i = 1, count do
		local waypoint = waypoints[i]
		local part = visualWaypoint:Clone()
		part.Position = waypoint.Position
		part.Color = (i == count and COLOR_END) or (waypoint.Action == JUMP and COLOR_JUMP) or COLOR_WALK
		part.Parent = workspace
		visualWaypoints[i] = part
	end
	return visualWaypoints
end

--Destroy visual waypoints
local function destroyVisualWaypoints(waypoints)
	if waypoints then
		for i = 1, #waypoints do
			waypoints[i]:Destroy()
		end
	end
	return false
end

--Get initial waypoint for non-humanoid
local function getNonHumanoidWaypoint(self)
	--Account for multiple waypoints that are sometimes in the same place
	local waypoints = self._waypoints
	for i = 2, #waypoints do
		if (waypoints[i].Position - waypoints[i - 1].Position).Magnitude > 0.1 then
			return i
		end
	end
	return 2
end

--Make NPC jump
local function tryJump(humanoid: Humanoid)
	local state = humanoid:GetState()
	if state ~= STATE_JUMPING and state ~= STATE_FREEFALL then
		humanoid:ChangeState(STATE_JUMPING)
	end
end

local function setJumpState(self)
	pcall(tryJump, self._humanoid)
end

--Disconnect MoveToFinished connection when pathfinding ends
local function disconnectMoveConnection(self)
	self._moveConnection:Disconnect()
	self._moveConnection = false
end

--Fire the WaypointReached event
local function invokeWaypointReached(self)
	local current = self._currentWaypoint
	self.WaypointReached:Fire(self._agent, self._waypoints[current - 1], self._waypoints[current])
end

local function moveToFinished(self, reached: boolean)

	--Stop execution if Path is destroyed
	if not getmetatable(self) then return end

	local waypoints = self._waypoints
	local waypointCount = self._count

	--Handle case for non-humanoids
	if not self._humanoid then
		if reached and self._currentWaypoint + 1 <= waypointCount then
			invokeWaypointReached(self)
			self._currentWaypoint += 1
		elseif reached then
			self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints)
			self._target = false
			self.Reached:Fire(self._agent, waypoints[self._currentWaypoint])
		else
			self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints)
			self._target = false
			declareError(self, self.ErrorType.TargetUnreachable)
		end
		return
	end

	local current = self._currentWaypoint
	if reached and current < waypointCount then --Waypoint reached
		if current + 1 < waypointCount then
			self.WaypointReached:Fire(self._agent, waypoints[current - 1], waypoints[current])
		end
		current += 1
		self._currentWaypoint = current
		local waypoint = waypoints[current]
		if waypoint.Action == JUMP then
			setJumpState(self)
		end
		self._humanoid:MoveTo(waypoint.Position)
	elseif reached then --Target reached, pathfinding ends
		disconnectMoveConnection(self)
		self.Status = STATUS_IDLE
		self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints)
		self.Reached:Fire(self._agent, waypoints[current])
	else --Target unreachable
		disconnectMoveConnection(self)
		self.Status = STATUS_IDLE
		self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints)
		declareError(self, self.ErrorType.TargetUnreachable)
	end
end

--Refer to Settings.COMPARISON_CHECKS
local STUCK_DISTANCE_SQ = 0.07 * 0.07
local function comparePosition(self, primaryPart: BasePart)
	if self._currentWaypoint == self._count then return end
	local position = primaryPart.Position
	local delta = position - self._lastPos
	local count = (delta:Dot(delta) <= STUCK_DISTANCE_SQ and self._stuckCount + 1) or 0
	self._stuckCount = count
	self._lastPos = position
	if count >= self._settings.COMPARISON_CHECKS then
		if self._settings.JUMP_WHEN_STUCK then
			setJumpState(self)
		end
		declareError(self, self.ErrorType.AgentStuck)
	end
end

--[[ STATIC METHODS ]]--
function Path.GetNearestCharacter(fromPosition: Vector3)
	local character, distSq = nil, math.huge
	for _, player in Players:GetPlayers() do
		local playerCharacter = player.Character
		local primaryPart = playerCharacter and playerCharacter.PrimaryPart
		if primaryPart then
			local offset = primaryPart.Position - fromPosition
			local d = offset:Dot(offset)
			if d < distSq then
				character, distSq = playerCharacter, d
			end
		end
	end
	return character
end

--[[ CONSTRUCTOR ]]--
function Path.new(agent: Model, agentParameters, override)
	if not (agent and agent:IsA("Model") and agent.PrimaryPart) then
		output(error, "Pathfinding agent must be a valid Model Instance with a set PrimaryPart.")
	end

	local humanoid = agent:FindFirstChildOfClass("Humanoid")

	local self = setmetatable({
		_settings = override or DEFAULT_SETTINGS;
		_agent = agent;
		_humanoid = humanoid;
		_path = PathfindingService:CreatePath(agentParameters);
		_t = 0;
		_lastPos = Vector3.zero;
		_stuckCount = 0;
		--state (false instead of nil so reads never fall through to a metatable miss)
		_waypoints = false;
		_count = false;
		_currentWaypoint = false;
		_target = false;
		_moveConnection = false;
		_visualWaypoints = false;
		_ownerPart = false;
		--public fields (signals stored directly on the object: one table less per Path)
		Status = STATUS_IDLE;
		Visualize = false;
		Reached = Signal.new();
		WaypointReached = Signal.new();
		Blocked = Signal.new();
		Error = Signal.new();
		Stopped = humanoid and Signal.new() or nil;
	}, Path)

	--Configure settings
	local settings = self._settings
	for setting, value in pairs(DEFAULT_SETTINGS) do
		if settings[setting] == nil then
			settings[setting] = value
		end
	end

	--Path blocked connection
	self._path.Blocked:Connect(function(blockedWaypointIndex)
		local current = self._currentWaypoint
		if current and self._humanoid and current <= blockedWaypointIndex and current + 1 >= blockedWaypointIndex then
			setJumpState(self)
			self.Blocked:Fire(self._agent, self._waypoints[blockedWaypointIndex])
		end
	end)

	return self
end


--[[ NON-STATIC METHODS ]]--
function Path:Destroy()
	if rawget(self, "Reached") then
		self.Reached:Destroy()
		self.WaypointReached:Destroy()
		self.Blocked:Destroy()
		self.Error:Destroy()
		local stopped = rawget(self, "Stopped")
		if stopped then
			stopped:Destroy()
		end
	end
	local moveConnection = rawget(self, "_moveConnection")
	if moveConnection then
		moveConnection:Disconnect()
	end
	if rawget(self, "_visualWaypoints") then
		destroyVisualWaypoints(self._visualWaypoints)
	end
	self._path:Destroy()
	setmetatable(self, nil)
	table.clear(self)
end

function Path:Stop()
	if not self._humanoid then
		output(error, "Attempt to call Path:Stop() on a non-humanoid.")
		return
	end
	if self.Status == STATUS_IDLE then
		output(warnTraceback, "Attempt to run Path:Stop() in idle state")
		return
	end
	disconnectMoveConnection(self)
	self.Status = STATUS_IDLE
	self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints)
	self.Stopped:Fire(self._agent)
end

function Path:Run(target)
	local humanoid = self._humanoid

	--Non-humanoid handle case
	if not target and not humanoid and self._target then
		moveToFinished(self, true)
		return
	end

	--Parameter check
	local isVector3 = typeof(target) == "Vector3"
	if not (target and (isVector3 or target:IsA("BasePart"))) then
		output(error, "Pathfinding target must be a valid Vector3 or BasePart.")
	end

	--Refer to Settings.TIME_VARIANCE
	if humanoid then
		local now = os.clock()
		local elapsed = now - self._t
		if elapsed <= self._settings.TIME_VARIANCE then
			task.wait(elapsed)
			declareError(self, self.ErrorType.LimitReached)
			return false
		end
		self._t = now
	end

	--Compute path
	local pathObject = self._path
	local primaryPart = self._agent.PrimaryPart
	local pathComputed = pcall(pathObject.ComputeAsync, pathObject, primaryPart.Position, isVector3 and target or target.Position)

	--Path was destroyed while ComputeAsync yielded
	if not getmetatable(self) then return false end

	--GetWaypoints is only called after the status checks, so a failed Run never
	--allocates the waypoint array; it also can never corrupt the waypoints of a
	--path that is still being walked
	local waypoints = false
	if pathComputed
		and pathObject.Status ~= NO_PATH
		and not (humanoid and humanoid:GetState() == STATE_FREEFALL) then
		waypoints = pathObject:GetWaypoints()
	end

	if not waypoints or #waypoints < 2 then
		self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints)
		task.wait()
		declareError(self, self.ErrorType.ComputationError)
		return false
	end

	--Set status to active; pathfinding starts
	self.Status = (humanoid and STATUS_ACTIVE) or STATUS_IDLE
	self._target = target

	--Set network owner to server to prevent "hops" (only needed once per PrimaryPart)
	if self._ownerPart ~= primaryPart then
		if pcall(primaryPart.SetNetworkOwner, primaryPart, nil) then
			self._ownerPart = primaryPart
		end
	end

	--Initialize waypoints
	self._waypoints = waypoints
	self._count = #waypoints
	self._currentWaypoint = 2

	--Refer to Settings.COMPARISON_CHECKS
	if humanoid then
		comparePosition(self, primaryPart)
	end

	--Visualize waypoints
	if self._visualWaypoints then
		destroyVisualWaypoints(self._visualWaypoints)
	end
	self._visualWaypoints = self.Visualize and createVisualWaypoints(waypoints)

	--Create a new move connection if it doesn't exist already
	if humanoid and not self._moveConnection then
		self._moveConnection = humanoid.MoveToFinished:Connect(function(reached)
			moveToFinished(self, reached)
		end)
	end

	--Begin pathfinding
	if humanoid then
		humanoid:MoveTo(waypoints[2].Position)
	elseif #waypoints == 2 then
		self._target = false
		self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints)
		self.Reached:Fire(self._agent, waypoints[2])
	else
		self._currentWaypoint = getNonHumanoidWaypoint(self)
		moveToFinished(self, true)
	end
	return true
end

return Path
