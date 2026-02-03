-- debug-runway-touch-getPlayer.lua
-- Отладочный скрипт DCS (2.9.6+): выводит сообщение "касание" при событии S_EVENT_RUNWAY_TOUCH
-- для самолёта, назначенного как "Player" (world.getPlayer()).
--
-- Запуск: DO SCRIPT FILE в миссии.

local S_EVENT_RUNWAY_TOUCH = 55

local function getSinglePlayerUnit()
  -- world.getPlayer() возвращает таблицу, где лежит объект Unit (в разных примерах это [1])
  local ok, t = pcall(world.getPlayer)
  if not ok or type(t) ~= "table" then return nil end

  -- наиболее типично: { [1] = Unit }
  local u = t[1]
  if u and u.isExist and u:isExist() then return u end

  -- на всякий случай: иногда могут вернуть { unit = Unit } или похожее
  for _, v in pairs(t) do
    if type(v) == "userdata" and v.isExist and v:isExist() then
      return v
    end
  end

  return nil
end

local handler = {}

function handler:onEvent(event)
  if not event or event.id ~= S_EVENT_RUNWAY_TOUCH then return end
  if not event.initiator or not event.initiator.isExist then return end

  local playerUnit = getSinglePlayerUnit()
  if not playerUnit then return end

  if event.initiator == playerUnit then
    trigger.action.outText("касание", 3)
  end
end

world.addEventHandler(handler)
