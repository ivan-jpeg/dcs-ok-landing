--[[ ok-landing.lua v2.2
  Утилита измерения максимальной перегрузки при посадке в DCS.
  Вызов: DO SCRIPT FILE в миссии.
  Радио-меню F10 → Other: «Старт измерения», «Сброс измерения», «Стоп измерения».
  Автозапуск при снижении ниже 100 м AGL, автоостановка при наборе выше 100 м AGL.
]]

local G = 9.81
local AGL_THRESHOLD = 100
local POLL_INTERVAL = 2.0
local UPDATE_INTERVAL = 0.1

-- Состояние по группе: currentNy, maxNy, measuring, showMessage, prevVel, prevTime, lastAGL
local stateByGroup = {}
local menuAddedForGroups = {}
local nextPollTime = 0
local nextUpdateTime = 0

local function formatMessage(currentNy, maxNy)
  local nyStr = string.format("%.2f", currentNy or 0)
  local maxStr = string.format("%.2f", maxNy or 0)
  return "Ny = " .. nyStr .. "\nNy(max) = " .. maxStr
end

local function getAGL(unit)
  if not unit or not unit:isExist() then return nil end
  local pos = unit:getPosition()
  if not pos or not pos.p then return nil end
  local landH = land.getHeight({ x = pos.p.x, y = pos.p.z })
  if not landH then return nil end
  return pos.p.y - landH
end

-- Полный сброс (при автоостановке по высоте)
local function fullReset(s)
  if not s then return end
  s.currentNy = 1
  s.maxNy = 1
  s.measuring = false
  s.showMessage = false
  s.prevVel = nil
  s.prevTime = nil
end

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
    groupName = group:getName()
  }

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
    -- Сброс только Ny(max); текущее Ny продолжает считаться
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

  missionCommands.addCommandForGroup(groupId, "Старт измерения", nil, onStart, groupInfo)
  missionCommands.addCommandForGroup(groupId, "Сброс измерения", nil, onReset, groupInfo)
  missionCommands.addCommandForGroup(groupId, "Стоп измерения", nil, onStop, groupInfo)
end

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

local function getUnitFromGroup(groupName)
  local group = Group.getByName(groupName)
  if not group or not group:isExist() then return nil end
  local unit = group:getUnit(1)
  if not unit or not unit:isExist() then return nil end
  return unit
end

-- Ny по оси Y в связанной (бортовой) СК: a_world = dv/dt, a_body_y = dot(a_world, bodyY), Ny = 1 + a_body_y/g
-- getPosition() возвращает pos.y = Vec3 (единичный вектор «вверх» самолёта в мировой СК)
local DEBUG_LOG_PATH = "/Users/ivanv/cursor-workspace/.cursor/debug.log"
local function debugLog(location, message, data, hypothesisId)
  -- #region agent log
  local ok, err = pcall(function()
    local f = io.open(DEBUG_LOG_PATH, "a")
    if f then
      local function esc(s) return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"' end
      local function num(v) return (type(v) == "number" and v ~= v) and "null" or tostring(v) end
      local parts = {}
      if data then
        for k, v in pairs(data) do
          if type(v) == "number" then parts[#parts+1] = esc(k) .. ":" .. num(v)
          else parts[#parts+1] = esc(k) .. ":" .. esc(tostring(v)) end
        end
      end
      local line = string.format('{"sessionId":"debug-session","runId":"run1","hypothesisId":%s,"location":%s,"message":%s,"timestamp":%d,"data":{%s}}\n',
        esc(hypothesisId or ""), esc(location), esc(message), os.time() * 1000, table.concat(parts, ","))
      f:write(line)
      f:close()
    end
  end)
  if not ok and err then env.info("[ok-landing] debugLog: " .. tostring(err)) end
  -- #endregion
end
local function computeNyBodyY(velNow, velPrev, dt, bodyY)
  if not velNow or not velPrev or dt <= 0 or not bodyY then return nil end
  local ax = (velNow.x - velPrev.x) / dt
  local ay = (velNow.y - velPrev.y) / dt
  local az = (velNow.z - velPrev.z) / dt
  local aBodyY = ax * bodyY.x + ay * bodyY.y + az * bodyY.z
  local NyCurrent = 1 + aBodyY / G
  -- #region agent log
  local NyAlt = (bodyY and bodyY.y) and (bodyY.y + aBodyY / G) or nil
  debugLog("computeNyBodyY", "Ny computed", {
    bodyY_y = bodyY.y, bodyY_x = bodyY.x, bodyY_z = bodyY.z,
    aBodyY = aBodyY, dt = dt, Ny = NyCurrent, Ny_alt_bodyY_y = NyAlt,
    ax = ax, ay = ay, az = az
  }, "A")
  -- #endregion
  return NyCurrent
end

local function updateNyAndMessage(t)
  for groupId, s in pairs(stateByGroup) do
    local unit = getUnitFromGroup(s.groupName)
    if not unit or not unit:isExist() then
      -- skip
    else
      local agl = getAGL(unit)
      if agl and type(agl) == "number" then
        -- Автоостановка только при переходе снизу вверх через 100 м (не при ручном старте выше 100 м)
        if s.measuring and (s.lastAGL ~= nil and s.lastAGL <= AGL_THRESHOLD) and agl > AGL_THRESHOLD then
          fullReset(s)
          trigger.action.outTextForGroup(groupId, "", 0.1, true)
        end
        -- Автозапуск: первое снижение ниже 100 м (переход сверху вниз)
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
        -- skip update
      else
        local pos = unit:getPosition()
        local vel = unit:getVelocity()
        if not pos or not pos.y or not vel then
          -- skip
        else
          local velCopy = { x = vel.x, y = vel.y, z = vel.z }
          local bodyY = pos.y
          if type(bodyY.x) ~= "number" or type(bodyY.y) ~= "number" or type(bodyY.z) ~= "number" then
            -- skip
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
              trigger.action.outTextForGroup(groupId, formatMessage(s.currentNy, s.maxNy), 1, true)
            end
          end
        end
      end
    end
  end
end

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

timer.scheduleFunction(scheduler, {}, timer.getTime() + 1)
