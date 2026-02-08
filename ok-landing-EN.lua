--[[ ok-landing-EN.lua v3.3
  Utility for measuring peak G-load at touchdown in DCS.
  Invocation: DO SCRIPT FILE in mission.
  Radio menu F10 → Other: "Start measurement", "Reset measurement", "Stop measurement".
  Auto start when descending below 100 m AGL, auto stop when climbing above 100 m AGL.
  On runway touch (S_EVENT_RUNWAY_TOUCH) with measurement active, shows "Landing" message for 20 s.
]]

-- =============================================================================
-- Constants and global state
-- =============================================================================

local G = 9.81
local AGL_THRESHOLD = 100
local POLL_INTERVAL = 2.0
local UPDATE_INTERVAL = 0.1
local S_EVENT_RUNWAY_TOUCH = 55
local LANDING_MESSAGE_DURATION = 20

local stateByGroup = {}
local menuAddedForGroups = {}
local nextPollTime = 0
local nextUpdateTime = 0

-- =============================================================================
-- Message formatting and AGL (height above ground) calculation
-- =============================================================================

--- Landing quality rating from maxNy: ≤1.7 — Excellent, 1.7–2.0 — Good,
--- 2.0–2.5 — Satisfactory, >2.5 — Hard landing.
local function getLandingRating(maxNy)
  local ny = maxNy or 0
  if ny <= 1.7 then return "\"Excellent!\""
  elseif ny <= 2.0 then return "\"Good\""
  elseif ny <= 2.5 then return "\"Satisfactory...\""
  else return "Hard landing!\n\n   Aircraft inspection required."
  end
end

--- Message with current and max G only.
local function formatMessage(currentNy, maxNy)
  local nyStr = string.format("%.2f", currentNy or 0)
  local maxStr = string.format("%.2f", maxNy or 0)
  return "\n\n   Ny = " .. nyStr .. "\n   Ny(max) = " .. maxStr .. "\n\n"
end

--- Message with current, max G and "G at touchdown" block with rating.
local function formatMessageWithLanding(currentNy, maxNy)
  local nyStr = string.format("%.2f", currentNy or 0)
  local maxStr = string.format("%.2f", maxNy or 0)
  local landingStr = string.format("%.2f", maxNy or 0)
  local rating = getLandingRating(maxNy)
  return "\n\n   Ny = " .. nyStr .. "\n   Ny(max) = " .. maxStr .. "\n\n   G at touchdown — " .. landingStr .. ",  " .. rating .. "\n\n"
end

--- Height above ground (AGL): unit altitude minus terrain height.
--- getPosition().p.y — altitude MSL; land.getHeight — terrain at (x, z).
local function getAGL(unit)
  if not unit or not unit:isExist() then return nil end
  local pos = unit:getPosition()
  if not pos or not pos.p then return nil end
  local landH = land.getHeight({ x = pos.p.x, y = pos.p.z })
  if not landH then return nil end
  return pos.p.y - landH
end

-- =============================================================================
-- State reset and radio menu
-- =============================================================================

--- Full reset of group state (on auto stop when climbing above 100 m AGL).
local function fullReset(s)
  if not s then return end
  s.currentNy = 1
  s.maxNy = 1
  s.measuring = false
  s.showMessage = false
  s.prevVel = nil
  s.prevTime = nil
  s.landingMessageUntilTime = nil
end

--- Adds radio menu items for the group and initializes state.
--- State is stored in stateByGroup[groupId]; each player (group) has its own counter.
local function addMenuForGroup(group)
  if not group or not group:isExist() then return end
  local groupId = group:getID()
  if menuAddedForGroups[groupId] then return end
  menuAddedForGroups[groupId] = true

  stateByGroup[groupId] = {
    currentNy = 1,
    maxNy = 1,
    measuring = false,
    showMessage = false,
    prevVel = nil,
    prevTime = nil,
    lastAGL = nil,
    groupName = group:getName(),
    landingMessageUntilTime = nil
  }
  -- #region agent log
  env.info("[ok-landing-debug] addMenuForGroup groupId=" .. tostring(groupId) .. " groupName=" .. tostring(group:getName()))
  -- #endregion

  local groupInfo = { groupId = groupId, groupName = group:getName() }

  local function onStart(_groupInfo)
    local s = stateByGroup[_groupInfo.groupId]
    if not s then return end
    s.measuring = true
    s.showMessage = true
    trigger.action.outTextForGroup(_groupInfo.groupId, formatMessage(s.currentNy, s.maxNy), 1, true)
  end

  local function onReset(_groupInfo)
    local s = stateByGroup[_groupInfo.groupId]
    if not s then return end
    s.maxNy = (s.currentNy and s.currentNy > 1) and s.currentNy or 1
    if s.showMessage then
      trigger.action.outTextForGroup(_groupInfo.groupId, formatMessage(s.currentNy, s.maxNy), 1, true)
    end
  end

  local function onStop(_groupInfo)
    local s = stateByGroup[_groupInfo.groupId]
    if not s then return end
    s.measuring = false
    s.showMessage = false
    trigger.action.outTextForGroup(_groupInfo.groupId, "", 0.1, true)
  end

  missionCommands.addCommandForGroup(groupId, "Start measurement", nil, onStart, groupInfo)
  missionCommands.addCommandForGroup(groupId, "Reset measurement", nil, onReset, groupInfo)
  missionCommands.addCommandForGroup(groupId, "Stop measurement", nil, onStop, groupInfo)
end

-- =============================================================================
-- Player polling and getting unit by group name
-- =============================================================================

--- Iterates RED and BLUE coalitions, finds players and adds menu for their groups.
local function pollPlayerGroups()
  for _, coalitionId in ipairs({ coalition.side.RED, coalition.side.BLUE }) do
    local players = coalition.getPlayers(coalitionId)
    if players then
      for i = 1, #players do
        local unit = players[i]
        if unit and unit:isExist() then
          local group = unit:getGroup()
          if group and group:isExist() then
            addMenuForGroup(group)
          end
        end
      end
    end
  end
end

--- Returns the first unit of the group by group name (Group.getByName + getUnit(1)).
local function getUnitFromGroup(groupName)
  local group = Group.getByName(groupName)
  if not group or not group:isExist() then return nil end
  local unit = group:getUnit(1)
  if not unit or not unit:isExist() then return nil end
  return unit
end

-- =============================================================================
-- Runway touch event
-- =============================================================================

--- On runway touch (S_EVENT_RUNWAY_TOUCH): if G measurement is on,
--- shows separate "Landing" message for 20 seconds for the player's group.
local function setupRunwayTouchHandler()
  -- #region agent log
  env.info("[ok-landing-debug] setupRunwayTouchHandler called S_EVENT_RUNWAY_TOUCH=" .. tostring(S_EVENT_RUNWAY_TOUCH))
  -- #endregion
  local handler = {}
  function handler:onEvent(event)
    -- #region agent log
    if event.id == S_EVENT_RUNWAY_TOUCH or event.id == 4 then
      env.info("[ok-landing-debug] onEvent id=" .. tostring(event.id) .. " time=" .. tostring(event.time))
    end
    -- #endregion
    if event.id ~= S_EVENT_RUNWAY_TOUCH then return end
    local initiator = event.initiator
    if not initiator or not initiator:isExist() then
      -- #region agent log
      env.info("[ok-landing-debug] runway_touch: no initiator or not exist")
      -- #endregion
      return
    end
    local group = initiator:getGroup()
    if not group or not group:isExist() then
      -- #region agent log
      env.info("[ok-landing-debug] runway_touch: no group or not exist")
      -- #endregion
      return
    end
    local groupId = group:getID()
    local s = stateByGroup[groupId]
    -- #region agent log
    env.info("[ok-landing-debug] runway_touch groupId=" .. tostring(groupId) .. " hasState=" .. tostring(s ~= nil) .. " measuring=" .. tostring(s and s.measuring or false))
    -- #endregion
    if not s or not s.measuring then return end
    s.landingMessageUntilTime = event.time + LANDING_MESSAGE_DURATION
    -- #region agent log
    env.info("[ok-landing-debug] outTextForGroup Landing groupId=" .. tostring(groupId))
    -- #endregion
    trigger.action.outTextForGroup(groupId, formatMessageWithLanding(s.currentNy, s.maxNy), 1, true)
  end
  world.addEventHandler(handler)
  -- #region agent log
  env.info("[ok-landing-debug] world.addEventHandler(handler) done")
  -- #endregion
end

-- =============================================================================
-- Ny (vertical G) calculation along body Y axis
-- =============================================================================

--- Computes vertical load factor Ny along aircraft body Y axis.
--- Uses: acceleration in world frame a = dv/dt, projection onto body Y (pos.y),
--- formula Ny = bodyY.y + aBodyY/G (gravity projection + excess acceleration in g).
--- getPosition().y — unit vector "up" of aircraft in world frame (DCS API).
local function computeNyBodyY(velNow, velPrev, dt, bodyY)
  if not velNow or not velPrev or dt <= 0 or not bodyY then return nil end
  local ax = (velNow.x - velPrev.x) / dt
  local ay = (velNow.y - velPrev.y) / dt
  local az = (velNow.z - velPrev.z) / dt
  local aBodyY = ax * bodyY.x + ay * bodyY.y + az * bodyY.z
  local NyCurrent = bodyY.y + aBodyY / G
  return NyCurrent
end

-- =============================================================================
-- Ny update for all groups, auto start/stop by AGL
-- =============================================================================

--- For each group with measurement: updates AGL, does auto start/stop at 100 m,
--- computes Ny from previous and current velocity, updates currentNy/maxNy and message.
local function updateNyAndMessage(t)
  for groupId, s in pairs(stateByGroup) do
    local unit = getUnitFromGroup(s.groupName)
    if not unit or not unit:isExist() then
      -- group has no unit — skip
    else
      local agl = getAGL(unit)
      if agl and type(agl) == "number" then
        if s.measuring and (s.lastAGL ~= nil and s.lastAGL <= AGL_THRESHOLD) and agl > AGL_THRESHOLD then
          fullReset(s)
          trigger.action.outTextForGroup(groupId, "", 0.1, true)
        end
        if not s.measuring and (s.lastAGL == nil or s.lastAGL >= AGL_THRESHOLD) and agl < AGL_THRESHOLD then
          s.measuring = true
          s.showMessage = true
          s.currentNy = 1
          s.maxNy = 1
          s.prevVel = nil
          s.prevTime = nil
        end
        s.lastAGL = agl
      end

      if not s.measuring then
        -- measurement off — do not update Ny
      else
        local pos = unit:getPosition()
        local vel = unit:getVelocity()
        if not pos or not pos.y or not vel then
          -- no orientation or velocity — skip
        else
          local velCopy = { x = vel.x, y = vel.y, z = vel.z }
          local bodyY = pos.y
          if type(bodyY.x) ~= "number" or type(bodyY.y) ~= "number" or type(bodyY.z) ~= "number" then
            -- invalid orientation — skip
          else
            if s.prevVel and s.prevTime and (t - s.prevTime) > 0.001 then
              local dt = t - s.prevTime
              local Ny = computeNyBodyY(velCopy, s.prevVel, dt, bodyY)
              if Ny and type(Ny) == "number" then
                s.currentNy = Ny
                if Ny > s.maxNy then
                  s.maxNy = Ny
                end
              end
            end

            s.prevVel = velCopy
            s.prevTime = t

            if s.showMessage then
              if s.landingMessageUntilTime and t < s.landingMessageUntilTime then
                trigger.action.outTextForGroup(groupId, formatMessageWithLanding(s.currentNy, s.maxNy), 1, true)
              else
                trigger.action.outTextForGroup(groupId, formatMessage(s.currentNy, s.maxNy), 1, true)
              end
            end
          end
        end
      end
    end
  end
end

-- =============================================================================
-- Scheduler and startup
-- =============================================================================

--- Timer: periodically polls player groups and updates Ny/messages.
--- updateNyAndMessage errors are logged via env.info, do not stop the loop.
local function scheduler(_args, t)
  if t >= nextPollTime then
    pollPlayerGroups()
    nextPollTime = t + POLL_INTERVAL
  end

  if t >= nextUpdateTime then
    local ok, err = pcall(updateNyAndMessage, t)
    if not ok and err then
      env.info("[ok-landing] updateNyAndMessage error: " .. tostring(err))
    end
    nextUpdateTime = t + UPDATE_INTERVAL
  end

  return t + 0.1
end

setupRunwayTouchHandler()
timer.scheduleFunction(scheduler, {}, timer.getTime() + 1)
