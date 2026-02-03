--[[ ok-landing.lua v5 — фикс Ny в момент касания через "impact" по вертикальному ускорению (не AGL),
     Lua 5.1. Работает устойчивее, чем детект AGL.

  Почему v4 мог показывать Ny=1:
    - maxNy теперь обновлялся только на "touchdown", а событие касания могло не детектиться
      (AGL на ВПП/склонах, onGround недоступен, порог/скорость не совпали) -> maxNy оставался 1.
    - дополнительно пики Ny могли быть очень короткими, и при редкой дискретизации их легко пропустить.

  Новый алгоритм:
    - currentNy вычисляется непрерывно как и раньше (1 + ay/g).
    - Касание/удар детектится по признаку резкого положительного вертикального ускорения ay
      (т.е. Ny превышает порог IMPACT_NY_THRESHOLD).
    - После детекта запускается сбор Ny в окне IMPACT_WINDOW_SEC и maxNy обновляется максимумом окна.
    - Антидребезг IMPACT_COOLDOWN_SEC.

  Автостарт/автостоп по AGL оставлен (ниже 100м включаем, выше — выключаем), если нет manualOverride.
  Ручные команды меню работают как раньше.
]]

local G = 9.81
local POLL_INTERVAL = 2.0
local UPDATE_INTERVAL = 0.02  -- чаще, чтобы поймать пики

local AUTO_AGL_THRESHOLD_M = 100.0
local AUTO_START_ENABLED = true

-- Детект "удара" (касания) по перегрузке
local IMPACT_NY_THRESHOLD = 1.30     -- порог Ny, выше которого считаем что начался "impact"
local IMPACT_WINDOW_SEC   = 0.60     -- сколько собираем Ny после триггера
local IMPACT_COOLDOWN_SEC = 1.50     -- минимальный интервал между касаниями

-- Доп. фильтры (чтобы не ловить манёвры в воздухе):
local IMPACT_AGL_MAX_M = 5.0         -- детект удара разрешён только ниже этой высоты AGL (если доступно)
local IMPACT_VY_MAX = 1.0            -- вертикальная скорость не должна быть сильно положительной (м/с)

-- Флаг для включения отладки
local DEBUG_CURRENT_NY = true  -- Установите в false для отключения отладки

-- state:
-- maxNy, measuring, showMessage, prevVel, prevTime, currentNy, groupName, manualOverride
-- impactCollecting(bool), impactT0(time), impactWindowMaxNy(number), lastImpactTime(time)
local stateByGroup = {}
local menuAddedForGroups = {}
local nextPollTime = 0
local nextUpdateTime = 0

local function formatMessage(maxNy, currentNy)
  local nyStr = string.format("%.2f", maxNy)
  local message = "Максимальная перегрузка\n______________________\n\nNy = " .. nyStr
  if DEBUG_CURRENT_NY and currentNy then
    message = message .. "\nТекущая Ny = " .. string.format("%.2f", currentNy)
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

local function getAGL(unit)
  if not unit or not unit:isExist() then return nil end
  local p = unit:getPoint()
  if not p or type(p.x) ~= "number" or type(p.y) ~= "number" or type(p.z) ~= "number" then return nil end
  local terrainH = land.getHeight({ x = p.x, y = p.z })
  if type(terrainH) ~= "number" then return nil end
  return p.y - terrainH
end

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
  s.impactCollecting = false
  s.impactT0 = nil
  s.impactWindowMaxNy = nil
  s.lastImpactTime = nil
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

    impactCollecting = false,
    impactT0 = nil,
    impactWindowMaxNy = nil,
    lastImpactTime = nil,
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
            if not s.measuring then startMeasuringForGroup(groupId, s) end
          else
            if s.measuring then stopMeasuringForGroup(groupId, s) end
          end
        end
      end
    end
  end
end

local function beginImpactCollection(s, t, Ny)
  s.impactCollecting = true
  s.impactT0 = t
  s.impactWindowMaxNy = Ny
end

local function finalizeImpactCollection(s)
  if s.impactWindowMaxNy and s.impactWindowMaxNy > s.maxNy then
    s.maxNy = s.impactWindowMaxNy
  end
  s.impactCollecting = false
  s.impactT0 = nil
  s.impactWindowMaxNy = nil
end

local function updateNyImpactAndMessage(t)
  for groupId, s in pairs(stateByGroup) do
    if s.measuring then
      local unit = getUnitFromGroup(s.groupName)
      if unit and unit:isExist() then
        local vel = unit:getVelocity()
        if vel and type(vel.y) == "number" then
          local velCopy = { x = vel.x, y = vel.y, z = vel.z }

          local Ny = nil
          if s.prevVel and s.prevTime and (t - s.prevTime) > 0.0005 then
            Ny = computeNyFromVelocity(velCopy, s.prevVel, t - s.prevTime)
          end
          s.currentNy = Ny

          -- Impact trigger logic
          if Ny and type(Ny) == "number" then
            local cooldownOk = true
            if s.lastImpactTime and (t - s.lastImpactTime) < IMPACT_COOLDOWN_SEC then
              cooldownOk = false
            end

            local vyOk = (velCopy.y <= IMPACT_VY_MAX)

            local aglOk = true
            local agl = getAGL(unit)
            if type(agl) == "number" then
              aglOk = (agl <= IMPACT_AGL_MAX_M)
            end

            if (not s.impactCollecting) and cooldownOk and vyOk and aglOk and (Ny >= IMPACT_NY_THRESHOLD) then
              s.lastImpactTime = t
              beginImpactCollection(s, t, Ny)
            end
          end

          -- If collecting, update window max and finalize when time elapsed
          if s.impactCollecting then
            if Ny and type(Ny) == "number" then
              if (not s.impactWindowMaxNy) or Ny > s.impactWindowMaxNy then
                s.impactWindowMaxNy = Ny
              end
            end
            if s.impactT0 and (t - s.impactT0) >= IMPACT_WINDOW_SEC then
              finalizeImpactCollection(s)
            end
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
    local ok1, err1 = pcall(applyAutoStartStopByAGL, t)
    if not ok1 and err1 then
      env.info("[ok-landing] applyAutoStartStopByAGL error: " .. tostring(err1))
    end

    local ok2, err2 = pcall(updateNyImpactAndMessage, t)
    if not ok2 and err2 then
      env.info("[ok-landing] updateNyImpactAndMessage error: " .. tostring(err2))
    end

    nextUpdateTime = t + UPDATE_INTERVAL
  end

  return t + 0.02
end

timer.scheduleFunction(scheduler, {}, timer.getTime() + 1)
