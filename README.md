# OK Landing

Utility for measuring peak **G-load at touchdown** in **DCS World**.

#### [Инструкция на русском](https://github.com/ivan-jpeg/dcs-ok-landing/blob/main/RU-README.md)

![](https://github.com/ivan-jpeg/dcs-ok-landing/blob/main/img/ok-banner.jpg)

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

![](https://github.com/ivan-jpeg/dcs-ok-landing/blob/main/img/editor.jpg)

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
