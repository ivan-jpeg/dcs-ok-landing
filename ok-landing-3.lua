--[[ ok-landing.lua v4 — Ny max фиксируется только при касании (touchdown), Lua 5.1
  Утилита измерения максимальной вертикальной перегрузки при посадке в DCS.
  Вызов: DO SCRIPT FILE в миссии.
  Радио-меню F10 → Other: «Старт измерения», «Сброс измерения», «Стоп измерения».

  Логика:
    - currentNy вычисляется непрерывно и (опционально) выводится как отладка.
    - maxNy обновляется ТОЛЬКО в момент касания земли (touchdown).
    - Касание детектится переходом AGL через порог TOUCHDOWN_AGL_M сверху вниз + признак "на земле"
      (если доступен) и/или отрицательная вертикальная скорость.
    - Вокруг события касания берётся окно значений Ny и в maxNy попадает максимум по окну.

  Автостарт/автостоп по AGL:
    - Ниже 100 м AGL: измерение включается (если нет manualOverride).
    - Выше 100 м AGL: измерение выключается (если нет manualOverride).
]]

local G = 9.81
local POLL_INTERVAL = 2.0
local UPDATE_INTERVAL = 0.05  -- чуть чаще, чтобы точнее поймать касание

local AUTO_AGL_THRESHOLD_M = 100.0
local AUTO_START_ENABLED = true

-- Детект касания
local TOUCHDOWN_AGL_M = 0.8          -- порог AGL для "контакта" (метры)
local TOUCHDOWN_VY_MAX = -0.2        -- vy должен быть <= этого (падает/не растёт), м/с
local TOUCHDOWN_COOLDOWN = 1.5       -- антидребезг касания, сек

-- Окно Ny вокруг касания (pre/post), сек
local TD_PRE_WINDOW = 0.30
local TD_POST_WINDOW = 0.40

-- Флаг для включения отладки
local DEBUG_CURRENT_NY = true  -- Установите в false для отключения отладки

-- Состояние по группе:
-- maxNy, measuring, showMessage, prevVel, prevTime, currentNy, groupName,
-- manualOverride (nil/true) - если true, авто-логика не вмешивается (после ручного Старт/Стоп)
-- prevAGL
-- tdCollecting (bool), tdT0 (time), tdWindowMaxNy (number), lastTouchdownTime (time)
local stateByGroup = {}
local menuAddedForGroups = {}
local nextPollTime = 0
local nextUpdateTime = 0

local function formatMessage(maxNy, currentNy)
  local nyStr = string.format("%.2f", maxNy)
  local message = "Максимальная перегрузка\n______________________\n\nNy = " .. nyStr

  if DEBUG_CURRENT_NY and currentNy then
    local currentNyStr = string.format("%.2f", currentNy)
    message = message .. "\nТекущая Ny = " .. currentNyStr
  end

  return message
end

local function getUnitFromGroup(groupName)
  local group = Group.getByName(groupName)
  if not group or not group:isExist() then return nil end
  local unit = group:getUnit(1)
  if not unit or not unit:isExist() then return nil end
  return unit
end

-- Высота AGL (над поверхностью) в метрах.
local function getAGL(unit)
  if not unit or not unit:isExist() then return nil end
  local p = unit:getPoint()
  if not p or type(p.x) ~= "number" or type(p.y) ~= "number" or type(p.z) ~= "number" then return nil end
  local terrainH = land.getHeight({ x = p.x, y = p.z })
  if type(terrainH) ~= "number" then return nil end
  return p.y - terrainH
end

-- Попытка определить "на земле" (не всегда доступно во всех контекстах/версиях)
local function isOnGround(unit)
  if not unit or not unit:isExist() then return nil end
  -- В некоторых версиях DCS есть Unit:inAir()
  if unit.inAir then
    local ok, res = pcall(function() return unit:inAir() end)
    if ok and type(res) == "boolean" then
      return (not res)
    end
  end
  return nil -- неизвестно
end

-- Вертикальная перегрузка Ny по скорости.
local function computeNyFromVelocity(velNow, velPrev, dt)
  if not velNow or not velPrev or dt <= 0 then return nil end
  local vy = velNow.y
  local vyPrev = velPrev.y
  if type(vy) ~= "number" or type(vyPrev) ~= "number" then return nil end
  local ay = (vy - vyPrev) / dt
  return 1 + ay / G
end

local function startMeasuringForGroup(groupId, s)
  if not s then return end
  s.measuring = true
  s.showMessage = true
  trigger.action.outTextForGroup(groupId, formatMessage(s.maxNy, s.currentNy), 1, true)
end

local function stopMeasuringForGroup(groupId, s)
  if not s then return end
  s.measuring = false
  s.showMessage = false
  trigger.action.outTextForGroup(groupId, "", 0.1, true)
end

local function resetMeasuringForGroup(groupId, s)
  if not s then return end
  s.maxNy = 1
  s.currentNy = nil
  s.prevVel = nil
  s.prevTime = nil
  s.prevAGL = nil
  s.tdCollecting = false
  s.tdT0 = nil
  s.tdWindowMaxNy = nil
  s.lastTouchdownTime = nil
  if s.showMessage then
    trigger.action.outTextForGroup(groupId, formatMessage(s.maxNy, s.currentNy), 1, true)
  end
end

local function addMenuForGroup(group)
  if not group or not group:isExist() then return end
  local groupId = group:getID()
  if menuAddedForGroups[groupId] then return end
  menuAddedForGroups[groupId] = true

  stateByGroup[groupId] = {
    maxNy = 1,
    measuring = false,
    showMessage = false,
    prevVel = nil,
    prevTime = nil,
    groupName = group:getName(),
    currentNy = nil,
    manualOverride = nil,

    prevAGL = nil,
    tdCollecting = false,
    tdT0 = nil,
    tdWindowMaxNy = nil,
    lastTouchdownTime = nil,
  }

  local groupInfo = { groupId = groupId, groupName = group:getName() }

  local function onStart(_groupInfo)
    local s = stateByGroup[_groupInfo.groupId]
    if not s then return end
    s.manualOverride = true
    startMeasuringForGroup(_groupInfo.groupId, s)
  end

  local function onReset(_groupInfo)
    local s = stateByGroup[_groupInfo.groupId]
    if not s then return end
    resetMeasuringForGroup(_groupInfo.groupId, s)
  end

  local function onStop(_groupInfo)
    local s = stateByGroup[_groupInfo.groupId]
    if not s then return end
    s.manualOverride = true
    stopMeasuringForGroup(_groupInfo.groupId, s)
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

local function applyAutoStartStopByAGL(_t)
  if not AUTO_START_ENABLED then return end

  for groupId, s in pairs(stateByGroup) do
    if not s.manualOverride then
      local unit = getUnitFromGroup(s.groupName)
      if unit and unit:isExist() then
        local agl = getAGL(unit)
        if type(agl) == "number" then
          if agl < AUTO_AGL_THRESHOLD_M then
            if not s.measuring then
              startMeasuringForGroup(groupId, s)
            end
          else
            if s.measuring then
              stopMeasuringForGroup(groupId, s)
            end
          end
        end
      end
    end
  end
end

local function beginTouchdownCollection(s, t, Ny)
  s.tdCollecting = true
  s.tdT0 = t
  s.tdWindowMaxNy = Ny or s.tdWindowMaxNy or nil
end

local function finalizeTouchdownCollection(s)
  if s.tdWindowMaxNy and (not s.maxNy or s.tdWindowMaxNy > s.maxNy) then
    s.maxNy = s.tdWindowMaxNy
  end
  s.tdCollecting = false
  s.tdT0 = nil
  s.tdWindowMaxNy = nil
end

local function updateNyTouchdownAndMessage(t)
  for groupId, s in pairs(stateByGroup) do
    if s.measuring then
      local unit = getUnitFromGroup(s.groupName)
      if unit and unit:isExist() then
        local vel = unit:getVelocity()
        local agl = getAGL(unit)

        if vel and type(vel.y) == "number" then
          -- copy
          local velCopy = { x = vel.x, y = vel.y, z = vel.z }

          -- currentNy (continuous)
          local Ny = nil
          if s.prevVel and s.prevTime and (t - s.prevTime) > 0.001 then
            local dt = t - s.prevTime
            Ny = computeNyFromVelocity(velCopy, s.prevVel, dt)
          end
          s.currentNy = Ny

          -- Touchdown detection and windowing
          local prevAGL = s.prevAGL
          local nowAGL = agl
          local vy = velCopy.y
          local onGround = isOnGround(unit) -- may be nil

          -- condition: crossed to near-ground and descending/not climbing
          local crossedToGround = false
          if type(prevAGL) == "number" and type(nowAGL) == "number" then
            if prevAGL > TOUCHDOWN_AGL_M and nowAGL <= TOUCHDOWN_AGL_M then
              crossedToGround = true
            end
          end

          local descending = (type(vy) == "number" and vy <= TOUCHDOWN_VY_MAX) or false
          local groundOk = (onGround == true) or (onGround == nil) -- if unknown, don't block

          local cooldownOk = true
          if s.lastTouchdownTime and type(s.lastTouchdownTime) == "number" then
            if (t - s.lastTouchdownTime) < TOUCHDOWN_COOLDOWN then
              cooldownOk = false
            end
          end

          if crossedToGround and descending and groundOk and cooldownOk then
            s.lastTouchdownTime = t
            beginTouchdownCollection(s, t, Ny)
          end

          -- While collecting: keep max Ny in window
          if s.tdCollecting then
            if Ny and type(Ny) == "number" then
              if (not s.tdWindowMaxNy) or Ny > s.tdWindowMaxNy then
                s.tdWindowMaxNy = Ny
              end
            end

            -- finalize after post window
            if s.tdT0 and (t - s.tdT0) >= TD_POST_WINDOW then
              finalizeTouchdownCollection(s)
            end
          else
            -- Also support a short "pre-window": when very low AGL, we can prefill window max
            -- to catch the peak slightly BEFORE crossing threshold. This is a simple heuristic:
            if type(nowAGL) == "number" and nowAGL <= (TOUCHDOWN_AGL_M + 0.5) then
              -- keep a rolling max over last TD_PRE_WINDOW seconds by piggybacking on prevTime
              -- Simplification: if we're in this zone and descending, store best Ny until touchdown triggers.
              if descending and Ny and type(Ny) == "number" then
                -- store in tdWindowMaxNy even before tdCollecting; beginTouchdownCollection will keep it
                if (not s.tdWindowMaxNy) or Ny > s.tdWindowMaxNy then
                  s.tdWindowMaxNy = Ny
                end
                -- expire prefill if too old (approx, based on prevTime)
                -- We'll reset it when we climb back up a bit.
              end
            else
              -- once we're not near ground, clear any prefill buffer
              s.tdWindowMaxNy = nil
            end
          end

          -- store prevs
          s.prevVel = velCopy
          s.prevTime = t
          s.prevAGL = nowAGL

          if s.showMessage then
            trigger.action.outTextForGroup(groupId, formatMessage(s.maxNy, s.currentNy), 1, true)
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
    local ok1, err1 = pcall(applyAutoStartStopByAGL, t)
    if not ok1 and err1 then
      env.info("[ok-landing] applyAutoStartStopByAGL error: " .. tostring(err1))
    end

    local ok2, err2 = pcall(updateNyTouchdownAndMessage, t)
    if not ok2 and err2 then
      env.info("[ok-landing] updateNyTouchdownAndMessage error: " .. tostring(err2))
    end

    nextUpdateTime = t + UPDATE_INTERVAL
  end

  return t + 0.05
end

timer.scheduleFunction(scheduler, {}, timer.getTime() + 1)
