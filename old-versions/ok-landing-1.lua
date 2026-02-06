# "ok-landing.lua"
--[[ ok-landing.lua v2 — без goto, Lua 5.1
  Утилита измерения максимальной перегрузки при посадке в DCS.
  Вызов: DO SCRIPT FILE в миссии.
  Радио-меню F10 → Other: «Старт измерения», «Сброс измерения», «Стоп измерения».
]]

local G = 9.81
local POLL_INTERVAL = 2.0
local UPDATE_INTERVAL = 0.1

-- Флаг для включения отладки
local DEBUG_CURRENT_NY = true  -- Установите в false для отключения отладки

-- Состояние по группе: maxNy, measuring, showMessage, prevVel, prevTime, currentNy
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
    currentNy = nil
  }

  local groupInfo = { groupId = groupId, groupName = group:getName() }

  local function onStart(_groupInfo)
    local s = stateByGroup[_groupInfo.groupId]
    if not s then return end
    s.measuring = true
    s.showMessage = true
    trigger.action.outTextForGroup(_groupInfo.groupId, formatMessage(s.maxNy, s.currentNy), 1, true)
  end

  local function onReset(_groupInfo)
    local s = stateByGroup[_groupInfo.groupId]
    if not s then return end
    s.maxNy = 1
    s.currentNy = nil
    s.prevVel = nil
    s.prevTime = nil
    if s.showMessage then
      trigger.action.outTextForGroup(_groupInfo.groupId, formatMessage(s.maxNy, s.currentNy), 1, true)
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

local function updateNyAndMessage(t)
  for groupId, s in pairs(stateByGroup) do
    if not s.measuring then
      -- skip
    else
      local unit = getUnitFromGroup(s.groupName)
      if not unit or not unit:isExist() then
        -- skip
      else
        -- Object.getVelocity(self) → vec3 (DCS API, Unit)
        local vel = unit:getVelocity()
        if not vel or type(vel.y) ~= "number" then
          -- skip
        else
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
    local ok, err = pcall(updateNyAndMessage, t)
    if not ok and err then
      env.info("[ok-landing] updateNyAndMessage error: " .. tostring(err))
    end
    nextUpdateTime = t + UPDATE_INTERVAL
  end

  return t + 0.1
end

timer.scheduleFunction(scheduler, {}, timer.getTime() + 1)
