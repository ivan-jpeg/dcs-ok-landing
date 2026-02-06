--[[ ok-landing.lua v3 — автостарт/автостоп по высоте AGL, Lua 5.1
  Утилита измерения максимальной перегрузки при посадке в DCS.
  Вызов: DO SCRIPT FILE в миссии.
  Радио-меню F10 → Other: «Старт измерения», «Сброс измерения», «Стоп измерения».

  Новое:
    - Автоматически включает измерение, когда самолёт игрока опускается ниже 100 м AGL.
    - Автоматически выключает измерение, когда поднимается выше 100 м AGL.
    - Ручные команды меню продолжают работать: можно принудительно стартовать/стопнуть/сбросить.
]]

local G = 9.81
local POLL_INTERVAL = 2.0
local UPDATE_INTERVAL = 0.1

local AUTO_AGL_THRESHOLD_M = 100.0
local AUTO_START_ENABLED = true

-- Флаг для включения отладки
local DEBUG_CURRENT_NY = true  -- Установите в false для отключения отладки

-- Состояние по группе:
-- maxNy, measuring, showMessage, prevVel, prevTime, currentNy, groupName,
-- manualOverride (nil/true) - если true, авто-логика не вмешивается (после ручного Старт/Стоп)
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

--[[
  Высота AGL (над поверхностью) в метрах.
  Берём: Unit:getPoint().y - land.getHeight({x=, y=})
  В DCS land.getHeight использует координаты {x, y} где y = z мировая.
]]
local function getAGL(unit)
  if not unit or not unit:isExist() then return nil end
  local p = unit:getPoint()
  if not p or type(p.x) ~= "number" or type(p.y) ~= "number" or type(p.z) ~= "number" then return nil end

  local terrainH = land.getHeight({ x = p.x, y = p.z })
  if type(terrainH) ~= "number" then return nil end

  return p.y - terrainH
end

--[[
  Вертикальная перегрузка Ny по скорости из Object.getVelocity() (vec3, Unit).
  a_y = d(v_y)/dt; Ny = 1 + a_y/g — отсчёт от 1G (покой на Земле).
]]
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
  -- не сбрасываем maxNy: старт/автостарт лишь включает измерение
  trigger.action.outTextForGroup(groupId, formatMessage(s.maxNy, s.currentNy), 1, true)
end

local function stopMeasuringForGroup(groupId, s)
  if not s then return end
  s.measuring = false
  s.showMessage = false
  -- при остановке окна скрываем; данные (maxNy) сохраняем
  trigger.action.outTextForGroup(groupId, "", 0.1, true)
end

local function resetMeasuringForGroup(groupId, s)
  if not s then return end
  s.maxNy = 1
  s.currentNy = nil
  s.prevVel = nil
  s.prevTime = nil
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
    manualOverride = nil, -- если true, автостарт/стоп не применяется
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
    -- Сброс не меняет режим (manualOverride остаётся как был)
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

local function applyAutoStartStopByAGL(t)
  if not AUTO_START_ENABLED then return end

  for groupId, s in pairs(stateByGroup) do
    -- Если пользователь вручную вмешался (Старт/Стоп), авто-режим для этой группы не трогаем
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

local function updateNyAndMessage(t)
  for groupId, s in pairs(stateByGroup) do
    if s.measuring then
      local unit = getUnitFromGroup(s.groupName)
      if unit and unit:isExist() then
        local vel = unit:getVelocity()
        if vel and type(vel.y) == "number" then
          -- копируем vec3, т.к. движок может переиспользовать таблицу
          local velCopy = { x = vel.x, y = vel.y, z = vel.z }

          if s.prevVel and s.prevTime and (t - s.prevTime) > 0.001 then
            local dt = t - s.prevTime
            local Ny = computeNyFromVelocity(velCopy, s.prevVel, dt)
            if Ny and type(Ny) == "number" and Ny > s.maxNy then
              s.maxNy = Ny
            end
            s.currentNy = Ny
          end

          s.prevVel = velCopy
          s.prevTime = t

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
    -- 1) Автостарт/автостоп по AGL
    local ok1, err1 = pcall(applyAutoStartStopByAGL, t)
    if not ok1 and err1 then
      env.info("[ok-landing] applyAutoStartStopByAGL error: " .. tostring(err1))
    end

    -- 2) Обновление Ny/максимума и сообщения
    local ok2, err2 = pcall(updateNyAndMessage, t)
    if not ok2 and err2 then
      env.info("[ok-landing] updateNyAndMessage error: " .. tostring(err2))
    end

    nextUpdateTime = t + UPDATE_INTERVAL
  end

  return t + 0.1
end

timer.scheduleFunction(scheduler, {}, timer.getTime() + 1)
