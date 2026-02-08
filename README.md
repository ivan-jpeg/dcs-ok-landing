# OK Landing

Stable release (v3.3) — utility for measuring peak **G-load at touchdown** in **DCS World**.

---

## Assess the quality of your landing

Whether you’re trying to **grease it on** or just get the bird down in one piece, the number that matters is what the **G-meter** says at touchdown. That’s what the tower and the rest of the flight will remember: did you **kiss the runway** and **roll the wheels on**, or did you **slam it in** and **smoke the tires** so maintenance has to swap gear? This script reads peak vertical G at **arrival** and displays it in the message window. The rating scale follows a four-level system (similar to maneuver aircraft checkride standards): from **greaser** to **hard landing**.

- **&lt; 1.7** — Excellent
- **&lt; 2.0** — Good
- **&lt; 2.5** — Satisfactory
- **&gt; 2.5** — Hard landing (inspect aircraft)

---

## How to load the script in the Mission Editor

1. Open your mission in the DCS **Mission Editor**.
2. Open the **Trigger** panel (mission triggers).
3. Create a **Once** trigger (or another that fires at mission start).
4. In the trigger’s actions, add:
   - **Action** → **DO SCRIPT FILE**
   - Select the path to `ok-landing-RU.lua` (e.g. copy the file into the mission folder and choose it there).
5. Save the mission.

> **Note:** The script runs in the Mission Scripting environment. The file must be available at the path you specify (typically the mission folder or a shared scripts folder).

---

## How to use the script in-game

### Radio menu (F10 → Other)

In flight, open the **radio menu** (**F10**), go to **Other**. You’ll see three options:

| Option | Action |
|--------|--------|
| **Start measurement** | Turn on G measurement; the message with current and max G (Ny and Ny max) appears on screen. |
| **Reset measurement** | Reset only **max** G — Ny(max); current Ny keeps updating. |
| **Stop measurement** | Turn off measurement and hide the message. |

### Automatic mode

- **Auto start:** When you descend below **100 m** AGL, measurement starts automatically.
- **Auto stop:** When you climb above **100 m** AGL, measurement stops and data is reset.

### On-screen messages

- While measuring, a block shows **Ny** (current G) and **Ny(max)** (peak for the run), updated about every 0.1 s.
- On **runway touch**, a **“Landing”** message appears with G and rating (Excellent / Good / Satisfactory / Hard landing) for 20 seconds.

---

## Summary

- **Load:** **DO SCRIPT FILE** in a mission trigger → select `ok-landing-RU.lua`.
- **In-game:** **F10** → **Other** → Start / Reset / Stop measurement.
- Auto start below 100 m AGL, auto stop above 100 m; on touchdown — message with G and rating.

# OK Landing

Релизная стабильная версия (v3.3) — утилита измерения максимальной перегрузки при посадке в **DCS World**.

---
## Оцени качество своей посадки

Несмотря на то, что техника выполнения посадки оценивается по множеству параметров, основным показателем мастерства вашей посадки всегда будет перегрузка при посадке. Именно это видит и будет обсуждать весь аэродром. Получается ли у вас «раскрутить колёса», или вы плюхаетесь с дымом так, что приходится менять пневматики после каждой смены. 

Скрипт замеряет максимально достигнутую перегрузку при касании и выводит в окно сообщения.. Оценка выставляется по шкале, принятой в ВВС СССР из КУЛП для маневренных самолётов по четырехбалльной шкале (зачётный полёт).

- < 1,7 — Отлично
- < 2,0 — Хорошо
- < 2,5 — Уовлеторительно
- \> 2,5 — Грубая посадка

---

## Как подключить скрипт в редакторе миссий

1. Откройте миссию в **Mission Editor** (Редактор миссий DCS).
2. Нажмите **Trigger** (Триггеры) или откройте панель триггеров миссии.
3. Создайте триггер типа **Once** (Однократно) или используйте подходящий по времени (например, при старте миссии).
4. В действиях триггера добавьте:
   - **Action** → **DO SCRIPT FILE**
   - Укажите путь к файлу `ok-landing-RU.lua` (например, скопируйте файл в папку миссии и выберите его).
5. Сохраните миссию.

> **Важно:** скрипт выполняется в среде Mission Scripting. Файл должен быть доступен редактору по указанному пути (обычно папка миссии или общая папка скриптов).

---

## Как пользоваться скриптом в игре

### Радио-меню (F10 → Other)

В полёте откройте **радио-меню** (**F10**), перейдите в раздел **Other** (Другое). Доступны три пункта:

| Пункт | Действие |
|-------|----------|
| **Старт измерения** | Включить измерение перегрузки, на экране появится сообщение с текущей и максимальной перегрузкой (Ny и Ny max). |
| **Сброс измерения** | Сбросить только **максимальную** перегрузку Ny(max); текущее Ny продолжает считаться. |
| **Стоп измерения** | Выключить измерение и скрыть сообщение. |

### Автоматический режим

- **Автозапуск:** при снижении ниже **100 м** над землёй (AGL) измерение включается автоматически.
- **Автоостановка:** при наборе высоты выше **100 м** AGL измерение выключается, данные сбрасываются.

### Сообщения на экране

- Во время измерения выводится блок с **Ny** (текущая перегрузка) и **Ny(max)** (максимальная за сессию), обновление примерно раз в 0,1 с.
- При **касании полосы** (посадка) выводится сообщение **«Посадка»** с перегрузкой и оценкой мягкости (Отлично / Хорошо / Удовлетворительно / Грубая посадка) на 20 секунд.

---

## Кратко

- Подключение: **DO SCRIPT FILE** в триггере миссии → выбор `ok-landing-RU.lua`.
- Управление в игре: **F10** → **Other** → «Старт измерения» / «Сброс измерения» / «Стоп измерения».
- Автостарт при высоте &lt; 100 м, автостоп при наборе &gt; 100 м; при посадке — сообщение с перегрузкой и оценкой.
