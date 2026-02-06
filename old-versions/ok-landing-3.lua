--[[ ok-landing.lua v6 — фиксация maxNy по событию DCS S_EVENT_RUNWAY_TOUCH (DCS 2.9.6+), Lua 5.1
  Утилита измерения максимальной вертикальной перегрузки при посадке (касание ВПП/палубы/ФАРП) игрока.

  Вызов: DO SCRIPT FILE в миссии.

  Меню F10 → Other (для группы игрока):
    - «Старт измерения»  : включает измерение и показывает окно
    - «Сброс измерения»  : сбрасывает maxNy и буферы
    - «Стоп измерения»   : останавливает измерение и скрывает окно

  Алгоритм:
    - currentNy вычисляется непрерывно из вертикального ускорения (dVy/dt) и может выводиться (DEBUG_CURRENT_NY).
    - maxNy обновляется ТОЛЬКО при получении события S_EVENT_RUNWAY_TOUCH для самолёта игрока:
        берём максимум Ny из окна вокруг события: [touchTime - PRE_TOUCH_SEC, touchTime + POST_TOUCH_SEC].
      Для этого ведётся кольцевой буфер последних Ny с таймстемпами и после касания ещё собираются значения POST окна.

  Примечания:
    - Событие S_EVENT_RUNWAY_TOUCH доступно с DCS 2.9.6.
    - Скрипт привязан к самолёту(самолётам) игроков через coalition.getPlayers(). Меню добавляется на группу игрока.
]]

local G = 9.81

local POLL_INTERVAL = 2.0
local UPDATE_INTERVAL = 0.02  -- чем меньше, тем лучше ловим пик Ny

-- Окно выборки вокруг касания
local PRE_TOUCH_SEC  = 0.35
local POST_TOUCH_SEC = 0.50

-- Размер буфера (сек) для хранения Ny-истории (должен быть > PRE_TOUCH_SEC с запасом)
local HISTORY_SEC = 2.0

-- Антидребезг: игнорировать повторные touchdown события в течение N секунд
local TOUCH_COOLDOWN_SEC = 1.0

-- Показывать текущую Ny в сообщении (отладка)
local DEBUG_CURRENT_NY = true

-- Event ID (на случай если env.mission не содержит констант)
local S_EVENT_RUNWAY_TOUCH = 55

-- stateByGroup[groupId] = {
--   maxNy, measuring, showMessage, prevVel, prevTime, currentNy, groupName, manualOverride,
--   history = { {t=, ny=} ... }, lastTouchTime,
--   postCollectUntil (time or nil), touchTime (time or nil), touchPlaceName (string or nil),
-- }
local stateByGroup = {}
local menuAddedForGroups = {}
local nextPollTime = 0
local nextUpdateTime = 0

-- Быстрый маппинг UnitName -> groupId (обновляется при polling игроков)
local unitNameToGroupId = {}

local function formatMessage(maxNy, currentNy)
  local nyStr = string.format("%.2f", maxNy or 1)
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

local function computeNyFromVelocity(velNow, velPrev, dt)
  if not velNow or not velPrev or dt <= 0 then return nil end
  local vy = velNow.y
  local vyPrev = velPrev.y
  if type(vy) ~= "number" or type(vyPrev) ~= "number" then return nil end
  local ay = (vy - vyPrev) / dt
  return 1 + ay / G
end

local function trimHistory(s, tNow)
  if not s.history then s.history = {} end
  local cutoff = tNow - HISTORY_SEC
  local h = s.history
  -- удаляем с начала, пока старое
  local i = 1
  while h[i] and h[i].t < cutoff do
    i = i + 1
  end
  if i > 1 then
    for j = i, #h do h[j - (i - 1)] = h[j] end
    for j = #h - (i - 2), #h do h[j] = nil end
  end
end

local function addHistoryPoint(s, t, Ny)
  if not Ny then return end
  if not s.history then s.history = {} end
  s.history[#s.history + 1] = { t = t, ny = Ny }
end

local function maxNyInWindow(s, t0, t1)
  if not s.history then return nil end
  local best = nil
  for i = 1, #s.history do
    local p = s.history[i]
    if p.t >= t0 and p.t <= t1 and type(p.ny) == "number" then
      if (not best) or p.ny > best then best = p.ny end
    end
  end
  return best
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
  s.history = {}
  s.lastTouchTime = nil
  s.postCollectUntil = nil
  s.touchTime = nil
  s.touchPlaceName = nil
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

    history = {},
    lastTouchTime = nil,
    postCollectUntil = nil,
    touchTime = nil,
    touchPlaceName = nil,
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
  unitNameToGroupId = {} -- перестраиваем каждый раз (дёшево)
  for _, coalitionId in ipairs({ coalition.side.RED, coalition.side.BLUE }) do
    local players = coalition.getPlayers(coalitionId)
    if players then
      for i = 1, #players do
        local unit = players[i]
        if unit and unit:isExist() then
          local group = unit:getGroup()
          if group and group:isExist() then
            addMenuForGroup(group)
            local gid = group:getID()
            local uname = unit:getName()
            if uname then unitNameToGroupId[uname] = gid end
          end
        end
      end
    end
  end
end

-- Обновление Ny (continuous), ведение истории, и финализация touchdown-окна после POST_TOUCH_SEC
local function updateNyHistoryAndMessage(t)
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

          if Ny and type(Ny) == "number" then
            addHistoryPoint(s, t, Ny)
            trimHistory(s, t)
          end

          -- Если после runway_touch мы собирали POST окно — проверим, не пора ли финализировать
          if s.postCollectUntil and t >= s.postCollectUntil and s.touchTime then
            local windowMax = maxNyInWindow(s, s.touchTime - PRE_TOUCH_SEC, s.touchTime + POST_TOUCH_SEC)
            if windowMax and windowMax > s.maxNy then
              s.maxNy = windowMax
            end
            s.postCollectUntil = nil
            s.touchTime = nil
            s.touchPlaceName = nil
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

-- Обработчик событий DCS
local okLandingEventHandler = {}

function okLandingEventHandler:onEvent(event)
  if not event or not event.id then return end

  if event.id ~= S_EVENT_RUNWAY_TOUCH then return end
  if not event.initiator or not event.initiator.getName then return end

  local uname
  local okName, resName = pcall(function() return event.initiator:getName() end)
  if okName then uname = resName end
  if not uname then return end

  local groupId = unitNameToGroupId[uname]
  if not groupId then
    -- На всякий случай попробуем найти по группе инициатора
    local okG, grp = pcall(function() return event.initiator:getGroup() end)
    if okG and grp and grp.getID then
      local okId, gid = pcall(function() return grp:getID() end)
      if okId then groupId = gid end
    end
  end
  if not groupId then return end

  local s = stateByGroup[groupId]
  if not s or not s.measuring then return end

  local t = event.time or timer.getTime()

  -- cooldown
  if s.lastTouchTime and (t - s.lastTouchTime) < TOUCH_COOLDOWN_SEC then
    return
  end
  s.lastTouchTime = t

  -- Ставим "в ожидание" POST окна: maxNy обновим когда окно закончится
  s.touchTime = t
  s.postCollectUntil = t + POST_TOUCH_SEC

  -- place (опционально, на будущее)
  if event.place and event.place.getName then
    local okP, pname = pcall(function() return event.place:getName() end)
    if okP then s.touchPlaceName = pname end
  end
end

world.addEventHandler(okLandingEventHandler)

-- Планировщик
local function scheduler(_args, t)
  if t >= nextPollTime then
    pollPlayerGroups()
    nextPollTime = t + POLL_INTERVAL
  end

  if t >= nextUpdateTime then
    local ok2, err2 = pcall(updateNyHistoryAndMessage, t)
    if not ok2 and err2 then
      env.info("[ok-landing] updateNyHistoryAndMessage error: " .. tostring(err2))
    end
    nextUpdateTime = t + UPDATE_INTERVAL
  end

  return t + 0.02
end

timer.scheduleFunction(scheduler, {}, timer.getTime() + 1)
