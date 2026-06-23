-- ProjectileTrajectoryPredictor
-- Forward-simulates BloxStrike grenade physics to predict landing position.
-- Mirrors ReplicatedStorage.Shared.6761911 (GrenadeSimulator) bit-for-bit.
--
-- Usage:
--   local Predictor = loadfile(...)()  -- or loadstring(FileRead(...))()
--   local landing = Predictor.predictLanding(state, config, raycastParams)
--   local arc    = Predictor.predictTrajectory(state, config, raycastParams, 128)
--
-- `state` and `config` shapes match the game's runtime tables exactly, so a
-- state captured from Projectile.Spawn can be passed in unchanged.

local Workspace = cloneref and cloneref(game:GetService("Workspace")) or game:GetService("Workspace")

local Predictor = {}

-- =========================================================================
-- Constants — verbatim from Shared.6761911.Constants
-- =========================================================================
Predictor.Constants = {
    SOURCE_TO_STUDS            = 0.0763888888888889,
    GRAVITY                    = Vector3.new(0, -23.833334, 0),     -- studs/sec^2 (downward)
    GRAVITY_ACCEL_MAG          = 23.83333396911621,                 -- positive magnitude; integrate() does vel.Y - dt*MAG
    MAX_THROW_VELOCITY         = 57.29166666666667,
    MAX_THROW_SPEED            = 50,
    MAX_JUMP_THROW_SPEED       = 62,
    FIXED_TIMESTEP             = 0.0078125,                          -- 1/128 s
    MAX_ITERATIONS_PER_FRAME   = 16,
    MAX_ACCUMULATED_TIME       = 0.1,
    MAX_SIMULATION_TIME        = 10,
    MAX_BOUNCES                = 20,
    RESTITUTION                = 0.4,
    JUMP_RESTITUTION           = 0.32,
    PLAYER_RESTITUTION_MULT    = 0.3,
    MAX_RESTITUTION            = 0.9,
    OVERBOUNCE                 = 2,
    STOP_EPSILON_SQUARED       = 2.3341049382716053,                 -- ~1.5278^2
    STOP_EPSILON               = 0.0076388888888888895,              -- per-axis zeroing
    GROUND_CHECK_DISTANCE      = 0.2,
    FLOOR_NORMAL_THRESHOLD     = 0.7,
    COLLISION_NORMAL_OFFSET    = 0.05,                               -- nudge off wall after bounce
    COLLISION_RADIUS_SCALE     = 0.01,                               -- radius*0.01 axis offsets
    SURFACE_PROBE_OFFSET       = 0.1,
    VELOCITY_SCALE             = 0.58,
    THROW_POWER_SCALE          = 0.7,
    THROW_POWER_BASE           = 0.3,
    THROW_UPWARD_BIAS_FAR      = 0.06,
    THROW_UPWARD_BIAS_NEAR     = 0.04,
    THROW_FORWARD_OFFSET       = 1.35,
    THROW_HEIGHT_OFFSET        = 2.4,
    PLAYER_VELOCITY_INHERIT    = 1.5,
    PLAYER_VERTICAL_VEL_SCALE  = 2,
    JUMP_THROW_FIXED_VERTICAL  = 20,
    JUMP_THROW_VEL_THRESHOLD   = 5,
    JUMP_THROW_HEIGHT_BONUS    = 0,
    JUMP_THROW_MIN_SPEED_BONUS = 62,
    JUMP_THROW_NORMAL_LOW_BONUS= -0.4,
}

local C = Predictor.Constants

-- =========================================================================
-- State / Config builders
-- =========================================================================

-- Builds the initial state table for a fresh throw. Mirrors createInitialState.
-- eyePos       : Vector3  (camera/throw origin)
-- lookDir      : Vector3  (unit look vector)
-- throwType    : "Far" | "Near"  (left-click = Far, right-click short = Near)
-- charVelocity : Vector3  (HumanoidRootPart.AssemblyLinearVelocity)
-- rangeScale   : number   (typically 1.0)
-- timestamp    : number   (workspace:GetServerTimeNow())
function Predictor.createInitialState(eyePos, lookDir, throwType, charVelocity, rangeScale, timestamp)
    local speed = ((throwType == "Far" and 1 or 0) * 0.7 + 0.3) * C.MAX_THROW_VELOCITY * rangeScale * C.VELOCITY_SCALE
    local isJumpThrow = charVelocity.Y > C.JUMP_THROW_VEL_THRESHOLD

    local verticalBoost
    if isJumpThrow then
        eyePos = eyePos + Vector3.new(0, 0, 0)  -- no-op, kept for parity
        verticalBoost = Vector3.new(0, C.JUMP_THROW_FIXED_VERTICAL, 0)
    else
        verticalBoost = Vector3.new(0, charVelocity.Y * C.PLAYER_VERTICAL_VEL_SCALE * C.VELOCITY_SCALE, 0)
    end

    local lateral
    if isJumpThrow then
        lateral = Vector3.new(lookDir.X * 1, lookDir.Y, lookDir.Z * 1).Unit
    else
        lateral = lookDir
    end

    local lateralScale = (not isJumpThrow) and 1 or 1
    local vel = lateral * speed
        + verticalBoost
        + (Vector3.new(lookDir.X * lateralScale, lookDir.Y, lookDir.Z * lateralScale).Unit * speed * 0.15)
        + Vector3.new(0, rangeScale * 6.5 * C.VELOCITY_SCALE, 0)

    -- clamp magnitude
    local maxSpeed = (not isJumpThrow) and C.MAX_THROW_SPEED
        or (lookDir.Y - C.JUMP_THROW_NORMAL_LOW_BONUS) * 20 + C.JUMP_THROW_MIN_SPEED_BONUS
    if maxSpeed < vel.Magnitude then
        vel = vel.Unit * maxSpeed
    end

    -- player velocity inheritance (horizontal only)
    vel = vel + Vector3.new(charVelocity.X, 0, charVelocity.Z) * C.PLAYER_VELOCITY_INHERIT

    -- angular velocity seeded from timestamp hash
    local t = math.floor(timestamp * 1000) % 1000
    local angX = t % 11 - 5
    local angY = math.floor(t / 11) % 13 - 6
    local angZ = math.floor(t / 143) % 11 - 5

    return {
        simulationTime   = 0,
        bounceCount      = 0,
        isGrounded       = false,
        isAtRest         = false,
        hasTouched       = false,
        accumulatedTime  = 0,
        position         = eyePos,
        velocity         = vel,
        angularVelocity  = Vector3.new(angX, angY, angZ),
        timestamp        = timestamp,
        isJumpThrow      = isJumpThrow,
    }
end

-- Builds a config table. Argument order mirrors the game's createConfig
-- EXACTLY: (radius, rangeScale, isNearThrow, fuseTime, minimumFuseTime, explodeOnFloorImpact).
function Predictor.createConfig(radius, rangeScale, isNearThrow, fuseTime, minimumFuseTime, explodeOnFloorImpact)
    return {
        restitution           = C.RESTITUTION,
        maxBounces            = C.MAX_BOUNCES,
        radius                = radius,
        fuseTime              = fuseTime,
        minimumFuseTime       = minimumFuseTime,
        explodeOnFloorImpact  = explodeOnFloorImpact,
        rangeScale            = rangeScale or 1,
        isNearThrow           = isNearThrow or false,
    }
end

-- Per-weapon physics defaults. Field names match Predictor.createConfig args.
-- Fuse times not authoritative — prefer values from Projectile.Spawn.Physics
-- at runtime when available. rangeScale=1, isNearThrow=false are safe defaults.
Predictor.WeaponDefaults = {
    ["HE Grenade"]         = { radius = 0.5, rangeScale = 1, isNearThrow = false, fuseTime = 1.6, minimumFuseTime = nil, explodeOnFloorImpact = false },
    ["Flashbang"]          = { radius = 0.5, rangeScale = 1, isNearThrow = false, fuseTime = 1.5, minimumFuseTime = nil, explodeOnFloorImpact = false },
    ["Smoke Grenade"]      = { radius = 0.5, rangeScale = 1, isNearThrow = false, fuseTime = 3.0, minimumFuseTime = nil, explodeOnFloorImpact = false },
    ["Decoy Grenade"]      = { radius = 0.5, rangeScale = 1, isNearThrow = false, fuseTime = 7.0, minimumFuseTime = nil, explodeOnFloorImpact = false },
    ["Molotov"]            = { radius = 0.5, rangeScale = 1, isNearThrow = false, fuseTime = nil, minimumFuseTime = 0.1, explodeOnFloorImpact = true },
    ["Incendiary Grenade"] = { radius = 0.5, rangeScale = 1, isNearThrow = false, fuseTime = nil, minimumFuseTime = 0.1, explodeOnFloorImpact = true },
}

-- =========================================================================
-- Physics — verbatim reimplementation of Shared.6761911 internals
-- =========================================================================

-- u61: clipVelocity. Removes the normal-component of velocity (scaled by overbounce).
local function clipVelocity(velocity, normal, overbounce)
    local d = velocity:Dot(normal) * overbounce
    local x = velocity.X - normal.X * d
    local y = velocity.Y - normal.Y * d
    local z = velocity.Z - normal.Z * d
    -- per-axis epsilon zeroing
    x = (math.abs(x) < C.STOP_EPSILON) and 0 or x
    y = (math.abs(y) < C.STOP_EPSILON) and 0 or y
    z = (math.abs(z) < C.STOP_EPSILON) and 0 or z
    return Vector3.new(x, y, z)
end
Predictor.clipVelocity = clipVelocity

-- u50.integrate: semi-implicit Euler. Grounded projectiles skip gravity.
function Predictor.integrate(position, velocity, dt, isGrounded)
    if isGrounded then
        return position + velocity * dt, velocity
    end
    -- Matches decompiled `v66 = p63.Y - p64 * 23.83333396911621` (positive magnitude, subtracted).
    local newVelY = velocity.Y - dt * C.GRAVITY_ACCEL_MAG
    local displacement = Vector3.new(
        velocity.X * dt,
        (velocity.Y + newVelY) / 2 * dt,
        velocity.Z * dt
    )
    return position + displacement, Vector3.new(velocity.X, newVelY, velocity.Z)
end

-- u50.calculateBounce
function Predictor.calculateBounce(velocity, normal, state, isPlayer)
    local newState = table.clone(state)
    local restitution = math.clamp(
        (state.isJumpThrow and C.JUMP_RESTITUTION or C.RESTITUTION) * (isPlayer and C.PLAYER_RESTITUTION_MULT or 1),
        0,
        C.MAX_RESTITUTION
    )
    local reflected = clipVelocity(velocity, normal, C.OVERBOUNCE) * restitution
    newState.bounceCount = state.bounceCount + 1
    newState.hasTouched  = true
    -- floor hit with tiny residual -> kill velocity entirely
    if normal.Y > C.FLOOR_NORMAL_THRESHOLD and reflected:Dot(reflected) < C.STOP_EPSILON_SQUARED then
        return Vector3.new(0, 0, 0), newState
    end
    return reflected, newState
end

-- u50.detectCollision: 7-ray sweep (center + 6 axis offsets at radius*0.01).
function Predictor.detectCollision(fromPos, toPos, radius, raycastParams)
    local delta = toPos - fromPos
    local distance = delta.Magnitude
    if distance < 0.001 then return nil end

    local offset = radius * C.COLLISION_RADIUS_SCALE
    local offsets = {
        Vector3.new( offset, 0, 0),
        Vector3.new(-offset, 0, 0),
        Vector3.new(0,  offset, 0),
        Vector3.new(0, -offset, 0),
        Vector3.new(0, 0,  offset),
        Vector3.new(0, 0, -offset),
    }

    local bestDist = math.huge
    local bestHit, bestOffset = nil, Vector3.new(0, 0, 0)

    local center = Workspace:Raycast(fromPos, delta, raycastParams)
    if center and center.Distance < bestDist then
        bestDist, bestHit = center.Distance, center
    end

    for _, off in ipairs(offsets) do
        local r = Workspace:Raycast(fromPos + off, delta, raycastParams)
        if r and r.Distance < bestDist then
            bestDist, bestHit, bestOffset = r.Distance, r, off
        end
    end

    if not bestHit then return nil end

    local hitPos = bestHit.Position - bestOffset
    local traveled = (hitPos - fromPos).Magnitude
    -- reject hits beyond the step length (plus small tolerance)
    if distance + offset + 0.1 < traveled then return nil end

    local inst = bestHit.Instance
    local parent = inst.Parent
    local isPlayer = parent and parent:FindFirstChildOfClass("Humanoid") ~= nil
    local isGlass = (parent and parent:HasTag("BreakableGlass")) or inst:HasTag("BreakableGlass")

    return {
        hit      = true,
        position = hitPos,
        normal   = bestHit.Normal,
        distance = traveled,
        instance = inst,
        isPlayer = isPlayer,
        isGlass  = isGlass,
    }
end

-- u50.checkGrounded: short downward probe.
function Predictor.checkGrounded(position, raycastParams)
    local r = Workspace:Raycast(position, Vector3.new(0, -C.GROUND_CHECK_DISTANCE, 0), raycastParams)
    if r then return true, r.Normal end
    return false, nil
end

-- u50.shouldStop
function Predictor.shouldStop(velocity, isGrounded, hasTouched)
    if isGrounded and hasTouched then
        return velocity:Dot(velocity) < C.STOP_EPSILON_SQUARED
    end
    return false
end

-- u50.step: one fixed-tick of simulation. Returns (newState, eventOrNil).
function Predictor.step(state, config, raycastParams, dt)
    local s = table.clone(state)
    s.simulationTime = state.simulationTime + dt

    -- timeout
    if s.simulationTime >= C.MAX_SIMULATION_TIME then
        s.isAtRest = true
        return s, { type = "timeout", timestamp = state.timestamp + s.simulationTime,
                    position = s.position, velocity = s.velocity, bounceCount = s.bounceCount }
    end
    -- fuse
    if config.fuseTime and s.simulationTime >= config.fuseTime then
        s.isAtRest = true
        return s, { type = "fuse", timestamp = state.timestamp + s.simulationTime,
                    position = s.position, velocity = s.velocity, bounceCount = s.bounceCount }
    end
    -- bounce cap
    if state.bounceCount >= config.maxBounces then
        s.isAtRest = true
        s.velocity = Vector3.new(0, 0, 0)
        return s, { type = "rest", timestamp = state.timestamp + s.simulationTime,
                    position = s.position, velocity = s.velocity, bounceCount = s.bounceCount }
    end

    local prevPos = s.position
    local newPos, newVel = Predictor.integrate(s.position, s.velocity, dt, s.isGrounded)
    local collision = Predictor.detectCollision(prevPos, newPos, config.radius, raycastParams)

    local event
    if collision then
        local bounceVel, bounceState = Predictor.calculateBounce(newVel, collision.normal, s, collision.isPlayer)
        s = bounceState
        s.position = collision.position + collision.normal * C.COLLISION_NORMAL_OFFSET
        s.velocity = bounceVel

        -- molotov / incendiary: detonate on first floor contact
        if config.explodeOnFloorImpact
           and collision.normal.Y > C.FLOOR_NORMAL_THRESHOLD
           and (not config.minimumFuseTime or s.simulationTime >= config.minimumFuseTime) then
            s.isAtRest = true
            return s, { type = "floor_impact", timestamp = state.timestamp + s.simulationTime,
                        position = s.position, normal = collision.normal,
                        velocity = s.velocity, bounceCount = s.bounceCount }
        end

        event = { type = "bounce", timestamp = state.timestamp + s.simulationTime,
                  position = s.position, normal = collision.normal,
                  velocity = s.velocity, bounceCount = s.bounceCount }
    else
        s.position = newPos
        s.velocity = newVel
    end

    local grounded, groundNormal = Predictor.checkGrounded(s.position, raycastParams)
    s.isGrounded = grounded

    -- still in flight?
    if not Predictor.shouldStop(s.velocity, grounded, s.hasTouched)
       or (config.minimumFuseTime and s.simulationTime < config.minimumFuseTime)
       or config.fuseTime then
        return s, event
    end

    -- come to rest
    s.isAtRest = true
    s.velocity = Vector3.new(0, 0, 0)
    s.angularVelocity = Vector3.new(0, 0, 0)
    return s, { type = "rest", timestamp = state.timestamp + s.simulationTime,
                position = s.position, velocity = s.velocity,
                normal = groundNormal or Vector3.new(0, 1, 0), bounceCount = s.bounceCount }
end

-- u50.simulate: per-frame accumulator driver. Use this if you want frame-accurate
-- co-simulation alongside the real grenade. Returns {state, events}.
function Predictor.simulate(state, config, raycastParams, frameDt)
    if state.isAtRest then
        if not config.fuseTime then
            return { state = state, events = {} }
        end
        local s = table.clone(state)
        s.simulationTime = state.simulationTime + frameDt
        if s.simulationTime >= config.fuseTime then
            return {
                state = s,
                events = { { type = "fuse", timestamp = state.timestamp + s.simulationTime,
                             position = s.position, velocity = s.velocity, bounceCount = s.bounceCount } },
            }
        end
        return { state = s, events = {} }
    end

    local s = table.clone(state)
    s.accumulatedTime = state.accumulatedTime + frameDt
    if s.accumulatedTime > C.MAX_ACCUMULATED_TIME then
        s.accumulatedTime = C.MAX_ACCUMULATED_TIME
    end

    local events, iters = {}, 0
    while s.accumulatedTime >= C.FIXED_TIMESTEP and iters < C.MAX_ITERATIONS_PER_FRAME do
        iters = iters + 1
        s.accumulatedTime = s.accumulatedTime - C.FIXED_TIMESTEP
        local ev
        s, ev = Predictor.step(s, config, raycastParams, C.FIXED_TIMESTEP)
        if ev then table.insert(events, ev) end
        if s.isAtRest then break end
    end
    return { state = s, events = events }
end

-- =========================================================================
-- High-level helpers — the ones you actually want to call
-- =========================================================================

-- Runs the simulation to completion in one shot (no frame pacing).
-- Returns a list of events (bounce/rest/fuse/floor_impact/timeout) plus the
-- final state. Each event carries an absolute `timestamp` and a world `position`.
function Predictor.simulateFull(state, config, raycastParams)
    local s = table.clone(state)
    s.accumulatedTime = 0
    local events = {}
    local guard = 0
    while not s.isAtRest and guard < 100000 do
        guard = guard + 1
        local ev
        s, ev = Predictor.step(s, config, raycastParams, C.FIXED_TIMESTEP)
        if ev then table.insert(events, ev) end
    end
    return s, events
end

-- Samples the trajectory at up to `maxSamples` evenly-spaced points along the
-- arc. Good for drawing a curved line / polyline. The final point is the rest
-- or detonation position.
function Predictor.predictTrajectory(state, config, raycastParams, maxSamples)
    maxSamples = maxSamples or 128
    local s = table.clone(state)
    s.accumulatedTime = 0
    local pts = { s.position }
    local guard = 0
    while not s.isAtRest and guard < 100000 do
        guard = guard + 1
        s = Predictor.step(s, config, raycastParams, C.FIXED_TIMESTEP)
        -- sub-sample to keep line smooth without storing every tick
        if #pts < maxSamples then
            table.insert(pts, s.position)
        end
    end
    if pts[#pts] ~= s.position then table.insert(pts, s.position) end
    return pts, s
end

-- The headline API. Returns where the grenade will end up.
--   result.restPosition       -> Vector3 (where it physically settles)
--   result.detonationPosition -> Vector3 (where it explodes; = restPosition for molotov/incen,
--                                          = midair fuse position for HE/flash/smoke)
--   result.detonationType     -> "rest" | "fuse" | "floor_impact" | "timeout"
--   result.detonationTime     -> absolute server timestamp
--   result.timeToDetonation   -> seconds from `state.timestamp`
--   result.bounceCount        -> number of bounces before stop
--   result.events             -> all events from simulateFull
function Predictor.predictLanding(state, config, raycastParams)
    local finalState, events = Predictor.simulateFull(state, config, raycastParams)
    local lastEvent = events[#events] or { type = "rest", position = finalState.position,
                                           timestamp = finalState.timestamp + finalState.simulationTime }

    local detonationPos, detonationType
    if lastEvent.type == "fuse" then
        detonationPos, detonationType = lastEvent.position, "fuse"
    elseif lastEvent.type == "floor_impact" then
        detonationPos, detonationType = lastEvent.position, "floor_impact"
    elseif lastEvent.type == "timeout" then
        detonationPos, detonationType = lastEvent.position, "timeout"
    else
        detonationPos, detonationType = finalState.position, "rest"
    end

    return {
        restPosition       = finalState.position,
        detonationPosition = detonationPos,
        detonationType     = detonationType,
        detonationTime     = lastEvent.timestamp,
        timeToDetonation   = lastEvent.timestamp - state.timestamp,
        bounceCount        = finalState.bounceCount,
        events             = events,
        finalState         = finalState,
    }
end

-- =========================================================================
-- Raycast params builder — match what the game uses (Observers.Game.Grenade.u8)
-- =========================================================================
-- `extraIgnore` is optional (e.g. the local character).
function Predictor.buildRaycastParams(grenadeModel, extraIgnore)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { Workspace:FindFirstChild("Debris") }
    if grenadeModel then table.insert(ignore, grenadeModel) end
    if extraIgnore then table.insert(ignore, extraIgnore) end
    params.FilterDescendantsInstances = ignore
    params.RespectCanCollide = false
    params.IgnoreWater = true
    return params
end

return Predictor
