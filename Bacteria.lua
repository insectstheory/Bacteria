-- bacteria.lua
-- bacterial colony sequencer for monome norns
--
-- NORNS CONTROLS
--   E1             = BPM
--   E2             = scale root / transpose
--   E3             = evolution speed (gens/beat)
--   K1 (hold) + E2 = birth threshold (B)
--   K1 (hold) + E3 = survive min (S_min)
--   K2             = reseed (gaussian blob from centre)
--   K3             = pause / resume evolution

engine.name = "None"

-- ─────────────────────────────────────────────
-- constants
-- ─────────────────────────────────────────────
local COLS    = 64
local ROWS    = 32
local CELL    = 2
local AGE_MAX = 32

local SCALES = {
  { name = "major",      steps = {0,2,4,5,7,9,11}             },
  { name = "minor",      steps = {0,2,3,5,7,8,10}             },
  { name = "pentatonic", steps = {0,2,4,7,9}                  },
  { name = "dorian",     steps = {0,2,3,5,7,9,10}             },
  { name = "phrygian",   steps = {0,1,3,5,7,8,10}             },
  { name = "chromatic",  steps = {0,1,2,3,4,5,6,7,8,9,10,11} },
  { name = "whole tone", steps = {0,2,4,6,8,10}               },
  { name = "dim",        steps = {0,2,3,5,6,8,9,11}           },
}

-- ─────────────────────────────────────────────
-- state
-- ─────────────────────────────────────────────
local grid_cur  = {}
local grid_nxt  = {}
local running   = true
local k1_held   = false
local midi_out  = nil
local gen_count = 0

local voices = {}

-- ─────────────────────────────────────────────
-- voice pool
-- ─────────────────────────────────────────────
local function voice_count() return #voices end

local function voice_release(pitch)
  for i = #voices, 1, -1 do
    if voices[i].pitch == pitch then table.remove(voices, i); return end
  end
end

local function voice_steal()
  if #voices == 0 then return end
  local oi = 1
  for i = 2, #voices do
    if voices[i].born_at < voices[oi].born_at then oi = i end
  end
  local v = voices[oi]; table.remove(voices, oi)
  if midi_out then midi_out:note_off(v.pitch, 0, params:get("midi_ch")) end
end

-- ─────────────────────────────────────────────
-- helpers
-- ─────────────────────────────────────────────
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function wraprc(r, c)
  return ((r - 1) % ROWS) + 1, ((c - 1) % COLS) + 1
end

local function count_neighbours(r, c)
  local n = 0
  for dr = -1, 1 do
    for dc = -1, 1 do
      if not (dr == 0 and dc == 0) then
        local nr, nc = wraprc(r + dr, c + dc)
        if grid_cur[nr][nc] > 0 then n = n + 1 end
      end
    end
  end
  return n
end

local function row_to_pitch(r, offset)
  offset = offset or 0
  local scale    = SCALES[params:get("scale")]
  local steps    = scale.steps
  local root     = params:get("root") - 1
  local base     = 60 + root
  local note_idx = ROWS - r
  local octave   = math.floor(note_idx / #steps)
  local degree   = note_idx % #steps
  return clamp(base + octave * 12 + steps[degree + 1] + offset, 0, 127)
end

local function birth_velocity(c, neighbours)
  local base = params:get("vel_base")
  return clamp(base + math.floor((c / COLS) * 20) + neighbours * 4, 1, 127)
end

local function death_velocity(age)
  local ratio = math.min((age - 1) / AGE_MAX, 1.0)
  return clamp(math.floor(params:get("vel_base") * 0.35 + ratio * 55), 1, 90)
end

local function age_to_level(age)
  if age <= 0 then return 0 end
  local ratio = 1.0 - math.min((age - 1) / AGE_MAX, 1.0)
  return math.floor(3 + ratio * 12)
end

-- ─────────────────────────────────────────────
-- MIDI
-- ─────────────────────────────────────────────
local function send_note(pitch, vel, dur_ms)
  if not midi_out then return end
  local ch = params:get("midi_ch")
  while voice_count() >= params:get("polyphony") do voice_steal() end
  table.insert(voices, { pitch = pitch, born_at = os.clock() })
  midi_out:note_on(pitch, vel, ch)
  clock.run(function()
    clock.sleep(dur_ms / 1000.0)
    midi_out:note_off(pitch, 0, ch)
    voice_release(pitch)
  end)
end

local function trigger_note(pitch, vel, dur_ms)
  if math.random() > (params:get("note_prob") / 100.0) then return end
  local jitter = params:get("jitter_ms")
  if jitter > 0 then
    clock.run(function()
      clock.sleep(math.random() * jitter / 1000.0)
      send_note(pitch, vel, dur_ms)
    end)
  else
    send_note(pitch, vel, dur_ms)
  end
end

-- ─────────────────────────────────────────────
-- Game of Life step
-- ─────────────────────────────────────────────
local function step()
  local B            = params:get("birth")
  local S_min        = params:get("surv_min")
  local S_max        = params:get("surv_max")
  local dur          = params:get("note_dur")
  local death_on     = params:get("death_notes") == 2
  local death_offset = params:get("death_offset")

  for r = 1, ROWS do
    grid_nxt[r] = grid_nxt[r] or {}
    for c = 1, COLS do
      local age      = grid_cur[r][c]
      local alive    = age > 0
      local n        = count_neighbours(r, c)
      local next_age = 0

      if alive then
        if n >= S_min and n <= S_max then
          next_age = age + 1
        else
          if death_on then
            trigger_note(row_to_pitch(r, death_offset), death_velocity(age), dur)
          end
          next_age = 0
        end
      else
        if n == B then
          trigger_note(row_to_pitch(r, 0), birth_velocity(c, n), dur)
          next_age = 1
        end
      end

      grid_nxt[r][c] = next_age
    end
  end

  grid_cur, grid_nxt = grid_nxt, grid_cur
  gen_count = gen_count + 1
end

-- ─────────────────────────────────────────────
-- seeding
-- ─────────────────────────────────────────────
local function init_grids()
  for r = 1, ROWS do
    grid_cur[r] = {}; grid_nxt[r] = {}
    for c = 1, COLS do grid_cur[r][c] = 0; grid_nxt[r][c] = 0 end
  end
end

local function reseed()
  local density = params:get("density") / 100.0
  local cr, cc  = ROWS / 2.0, COLS / 2.0
  local sr, sc  = ROWS * 0.18, COLS * 0.18
  for r = 1, ROWS do
    for c = 1, COLS do
      local dr   = (r - cr) / sr
      local dc   = (c - cc) / sc
      local prob = density * math.exp(-0.5 * (dr * dr + dc * dc))
      grid_cur[r][c] = (math.random() < prob) and 1 or 0
    end
  end
  gen_count = 0
end

-- ─────────────────────────────────────────────
-- OLED screen
-- ─────────────────────────────────────────────
local function draw_colony()
  for r = 1, ROWS do
    for ci = 0, COLS - 1 do
      local c   = (ci % COLS) + 1
      local age = grid_cur[r][c]
      if age > 0 then
        screen.level(age_to_level(age))
        screen.pixel(ci * CELL, (r - 1) * CELL)
        screen.fill()
      end
    end
  end
end

local function draw_info()
  screen.level(0)
  screen.rect(0, 58, 128, 6)
  screen.fill()
  screen.level(3)
  screen.move(2, 63)
  local sname  = SCALES[params:get("scale")].name
  local rnames = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
  local rname  = rnames[((params:get("root") - 1) % 12) + 1]
  local dmark  = (params:get("death_notes") == 2) and "†" or " "
  screen.text(string.format("g:%d %s%s p%d%s",
    gen_count, rname, sname, params:get("note_prob"), dmark))
  if not running then
    screen.level(10); screen.move(114, 63); screen.text("||")
  end
end

function redraw()
  screen.clear()
  draw_colony()
  draw_info()
  screen.update()
end

-- ─────────────────────────────────────────────
-- clock
-- ─────────────────────────────────────────────
local seq_clock = nil

local function start_clock()
  if seq_clock then clock.cancel(seq_clock) end
  seq_clock = clock.run(function()
    while true do
      clock.sync(1 / params:get("evo_speed"))
      if running then
        step()
        redraw()
      end
    end
  end)
end

-- ─────────────────────────────────────────────
-- norns callbacks
-- ─────────────────────────────────────────────
function key(n, z)
  if n == 1 then
    k1_held = (z == 1)
  elseif n == 2 and z == 1 then
    reseed(); redraw()
  elseif n == 3 and z == 1 then
    running = not running; redraw()
  end
end

function enc(n, d)
  if n == 1 then
    params:delta("clock_tempo", d)
  elseif n == 2 then
    if k1_held then params:delta("birth", d)
    else             params:delta("root",  d) end
    redraw()
  elseif n == 3 then
    if k1_held then params:delta("surv_min",  d)
    else             params:delta("evo_speed", d) end
    redraw()
  end
end

-- ─────────────────────────────────────────────
-- reset parametri ai default
-- ─────────────────────────────────────────────
local function reset_params()
  params:set("scale",        3)
  params:set("root",         0)
  params:set("midi_ch",      1)
  params:set("vel_base",    70)
  params:set("note_dur",    80)
  params:set("polyphony",    6)
  params:set("note_prob",   80)
  params:set("jitter_ms",    0)
  params:set("death_notes",  1)
  params:set("death_offset",-12)
  params:set("density",     30)
  params:set("birth",        3)
  params:set("surv_min",     2)
  params:set("surv_max",     3)
  params:set("evo_speed",    2)
end

-- ─────────────────────────────────────────────
-- init
-- ─────────────────────────────────────────────
function init()
  midi_out = midi.connect(1)

  params:add_separator("BACTERIA")
  params:add_option("scale", "scale",
    (function()
      local t = {}
      for _, s in ipairs(SCALES) do t[#t + 1] = s.name end
      return t
    end)(), 3)
  params:add_number("root",     "root (semitones)",   -12, 12,  0)
  params:add_number("midi_ch",  "MIDI channel",          1, 16,  1)
  params:add_number("vel_base", "velocity base",        40,100, 70)
  params:add_number("note_dur", "note duration (ms)",   10,500, 80)
  params:add_number("polyphony","max polyphony",          1, 16,  6)

  params:add_separator("EXPRESSION")
  params:add_number("note_prob",    "note probability %",  1,100, 80)
  params:add_number("jitter_ms",    "jitter (ms)",         0,200,  0)
  params:add_option("death_notes",  "death notes", {"off","on"}, 1)
  params:add_number("death_offset", "death pitch offset", -24, 24,-12)

  params:add_separator("COLONY")
  params:add_number("density",  "seed density %",   5, 80, 30)
  params:add_number("birth",    "birth (B)",         1,  8,  3)
  params:add_number("surv_min", "survive min (S)",   1,  8,  2)
  params:add_number("surv_max", "survive max (S)",   1,  8,  3)

  params:add_separator("TIMING")
  params:add_number("evo_speed","evo speed (gens/beat)", 1, 16, 2)

  params:bang()
  reset_params()   -- sovrascrive qualsiasi valore salvato su disco

  math.randomseed(os.time())
  init_grids()
  reseed()
  start_clock()
  redraw()
end

function cleanup()
  if seq_clock then clock.cancel(seq_clock) end
  voices = {}
  if midi_out then
    for n = 0, 127 do
      midi_out:note_off(n, 0, params:get("midi_ch"))
    end
  end
end
