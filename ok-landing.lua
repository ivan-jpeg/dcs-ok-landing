--[[ ok-landing.lua v3.2
  Утилита измерения максимальной перегрузки при посадке в DCS.
  Вызов: DO SCRIPT FILE в миссии.
  Радио-меню F10 → Other: «Старт измерения», «Сброс измерения», «Стоп измерения».
  Автозапуск при снижении ниже 100 м AGL, автоостановка при наборе выше 100 м AGL.
  При касании полосы (S_EVENT_RUNWAY_TOUCH) и включённом замере выводится сообщение «Посадка» на 10 с.
]]

-- =============================================================================
-- Константы и глобальное состояние
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
-- Форматирование сообщения и расчёт высоты над землёй
-- =============================================================================

--- Оценка мягкости посадки по maxNy: до 1.7 — Отлично, 1.7–2.0 — Хорошо,
--- 2.0–2.5 — Удовлетворительно, выше 2.5 — Грубая посадка.
local function getLandingRating(maxNy)
  local ny = maxNy or 0
  if ny <= 1.7 then return "Отлично!"
  elseif ny <= 2.0 then return "Хорошо"
  elseif ny <= 2.5 then return "Удовлетворительно"
  else return "Грубая посадка! Требуется осмотр самолёта"
  end
end

--- Сообщение только с текущей и максимальной перегрузкой.
local function formatMessage(currentNy, maxNy)
  local nyStr = string.format("%.2f", currentNy or 0)
  local maxStr = string.format("%.2f", maxNy or 0)
  return "\n\n   Ny = " .. nyStr .. "\n   Ny(max) = " .. maxStr .. "\n\n"
end

--- Сообщение с текущей, максимальной перегрузкой и блоком «Перегрузка при посадке» с оценкой.
local function formatMessageWithLanding(currentNy, maxNy)
  local nyStr = string.format("%.2f", currentNy or 0)
  local maxStr = string.format("%.2f", maxNy or 0)
  local landingStr = string.format("%.2f", maxNy or 0)
  local rating = getLandingRating(maxNy)
  return "\n\n   Ny = " .. nyStr .. "\n   Ny(max) = " .. maxStr .. "\n\n   Перегрузка при посадке — " .. landingStr .. ",  «" .. rating .. "»\n\n"
end

--- Высота над землёй (AGL): разница между высотой единицы и высотой рельефа.
--- getPosition().p.y — высота над уровнем моря; land.getHeight — рельеф в точке (x, z).
local function getAGL(unit)
  if not unit or not unit:isExist() then return nil end
  local pos = unit:getPosition()
  if not pos or not pos.p then return nil end
  local landH = land.getHeight({ x = pos.p.x, y = pos.p.z })
  if not landH then return nil end
  return pos.p.y - landH
end

-- =============================================================================
-- Сброс состояния и радио-меню
-- =============================================================================

--- Полный сброс состояния группы (при автоостановке по набору высоты > 100 м AGL).
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

--- Добавляет для группы пункты радио-меню и инициализирует состояние.
--- Состояние хранится в stateByGroup[groupId]; каждый игрок (группа) имеет свой счётчик.
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

  missionCommands.addCommandForGroup(groupId, "Старт измерения", nil, onStart, groupInfo)
  missionCommands.addCommandForGroup(groupId, "Сброс измерения", nil, onReset, groupInfo)
  missionCommands.addCommandForGroup(groupId, "Стоп измерения", nil, onStop, groupInfo)
end

-- =============================================================================
-- Опрос игроков и получение юнита по имени группы
-- =============================================================================

--- Проходит по коалициям RED и BLUE, находит игроков и добавляет меню для их групп.
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

--- Возвращает первый юнит группы по имени группы (Group.getByName + getUnit(1)).
local function getUnitFromGroup(groupName)
  local group = Group.getByName(groupName)
  if not group or not group:isExist() then return nil end
  local unit = group:getUnit(1)
  if not unit or not unit:isExist() then return nil end
  return unit
end

-- =============================================================================
-- Событие касания полосы (runway touch)
-- =============================================================================

--- При касании полосы (S_EVENT_RUNWAY_TOUCH): если замер перегрузки включён,
--- выводит отдельное сообщение «Посадка» на 10 секунд для группы игрока.
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
    env.info("[ok-landing-debug] outTextForGroup Посадка groupId=" .. tostring(groupId))
    -- #endregion
    trigger.action.outTextForGroup(groupId, formatMessageWithLanding(s.currentNy, s.maxNy), 1, true)
  end
  world.addEventHandler(handler)
  -- #region agent log
  env.info("[ok-landing-debug] world.addEventHandler(handler) done")
  -- #endregion
end

-- =============================================================================
-- Расчёт перегрузки Ny по оси Y в связанной (бортовой) СК
-- =============================================================================

--- Вычисляет вертикальную перегрузку Ny по оси Y самолёта в связанной СК.
--- Используется: ускорение в мировой СК a = dv/dt, проекция на ось Y самолёта (pos.y),
--- формула Ny = bodyY.y + aBodyY/G (проекция гравитации + избыточное ускорение в g).
--- getPosition().y — единичный вектор «вверх» самолёта в мировой СК (DCS API).
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
-- Обновление Ny по всем группам, автостарт/автостоп по AGL
-- =============================================================================

--- Для каждой группы с измерением: обновляет AGL, выполняет автостарт/автостоп по 100 м,
--- считает Ny по предыдущей и текущей скорости, обновляет currentNy/maxNy и сообщение.
local function updateNyAndMessage(t)
  for groupId, s in pairs(stateByGroup) do
    local unit = getUnitFromGroup(s.groupName)
    if not unit or not unit:isExist() then
      -- группа без юнита — пропуск
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
        -- измерение выключено — не обновляем Ny
      else
        local pos = unit:getPosition()
        local vel = unit:getVelocity()
        if not pos or not pos.y or not vel then
          -- нет ориентации или скорости — пропуск
        else
          local velCopy = { x = vel.x, y = vel.y, z = vel.z }
          local bodyY = pos.y
          if type(bodyY.x) ~= "number" or type(bodyY.y) ~= "number" or type(bodyY.z) ~= "number" then
            -- некорректная ориентация — пропуск
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
-- Планировщик и запуск
-- =============================================================================

--- Таймер: периодически опрашивает группы игроков и обновляет Ny/сообщения.
--- Ошибки updateNyAndMessage логируются через env.info, не прерывают работу.
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
