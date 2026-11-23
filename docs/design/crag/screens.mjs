const T = (id, markdown, o = {}) => ({ type: "text", id, markdown, ...o });
const stat = (id, items) => ({ type: "stat", id, items: items.map(([value, label, unit]) => ({ value, label, ...(unit ? { unit } : {}) })) });
const card = (id, title, subtitle, blocks, o = {}) => ({ type: "card", id, title, ...(subtitle ? { subtitle } : {}), blocks, ...o });
const row = (id, title, subtitle, value, o = {}) => ({ type: "row", id, title, ...(subtitle ? { subtitle } : {}), ...(value ? { value } : {}), ...o });
const list = (id, rows) => ({ type: "list", id, rows });
const btn = (id, label, style, action = id) => ({ type: "button", id, label, action, ...(style ? { style } : {}) });
const sec = (id, header, blocks, footer) => ({ type: "section", id, header, blocks, ...(footer ? { footer } : {}) });
const chips = (id, name, opts, selected) => ({ type: "chips", id, name, options: opts.map((l) => ({ label: l, value: l })), selected: [selected] });
const tick = (id, g, n, s, t, tone) => row(id, n, s, t, { badge: { text: g, tone: tone || "mute" }, accessory: "chevron" });
const steps = (id, labels, current) => ({ type: "steps", id, steps: labels.map((l, i) => ({ id: `s${i}`, label: l })), current: `s${current}` });

const TICKS = [
  ["t1", "V5", "Moon Arete", "Pine Gully · today", "Flash", "accent"],
  ["t2", "V4", "Slab Crack", "Pine Gully · today", "Send", "ok"],
  ["t3", "6B+", "Warm-up 3", "Home board · Fri", "Send", "ok"],
  ["t4", "V6", "Night Shift", "Pine Gully · 14 Nov", "Project", "warn"],
];
const ticks = (n) => list("ticks", TICKS.slice(0, n).map((t) => tick(...t)));
const conditions = card("conditions", "Pine Gully", "14° · 52% · Friction 78 ›", [], { tap: { action: "conditions" } });

export const SCREENS = {
  today: { tab: "today", title: "Today", blocks: [
    conditions,
    { type: "crag-moon", id: "meter", value: 82, date: "Sun 22 Nov", hrv: ["64 ms", "+6", 0.72], sleep: ["7h 40", "92%", 0.86] },
    btn("start", "Start session", "primary"),
    card("week", "This week", null, [stat("wk", [["4", "Sessions"], ["12", "Sends"], ["V6", "Top"]])]),
  ], wideExtra: [card("last", "Last ticks", null, [ticks(3)])] },

  conditions: { tab: "today", pushed: true, title: "Send conditions", back: "Today", blocks: [
    card("now", "Pine Gully · now", "Open-Meteo", [stat("f", [["78", "Friction"], ["Good", "Ranks 6 of 30"]]), stat("w", [["14°", "Temp"], ["52%", "Humidity"], ["6°", "Dew point"], ["9", "Wind km/h"]])]),
    { type: "chart", id: "d30", chart: "bar", title: "Friction, last 30 days", x: [...Array(30)].map((_, i) => `${i + 1}`), series: [{ name: "Friction", values: [52, 60, 48, 71, 66, 58, 74, 80, 62, 55, 49, 61, 69, 72, 77, 64, 58, 50, 57, 63, 70, 75, 81, 68, 60, 54, 66, 73, 76, 78] }] },
    card("best", "Best window today", null, [T("bw", "18:00 – 21:00 · friction 84")]),
  ] },

  session: { tab: "session", title: "Session", blocks: [
    stat("live", [["1:12", "Time"], ["9", "Tries"], ["5", "Sends"], ["V5", "Top"], ["142", "HR"]]),
    card("on", "On now", "Try 3", [T("rn", "**Moon Arete** · V5")]),
    btn("sent", "Sent", "primary"), btn("fell", "Fell", "plain"),
    card("lt", "Last ticks", "All 14 ›", [ticks(2)]),
    btn("end", "End session", "destructive"),
  ] },

  send: { tab: "session", pushed: true, title: "", blocks: [
    { type: "crag-roo", id: "m", pose: "flash", size: 210, word: "Flashed!", line: "Moon Arete · V5 · first try" },
    stat("s", [["5", "Sends today"], ["V5", "Top"], ["1st", "Flash at V5"]]),
    btn("done", "Done", "primary"), btn("note", "Add a note", "plain"),
  ] },

  board: { tab: "board", title: "Board", blocks: [
    chips("set", "set", ["Kilter 40°", "Moon 2019", "Home"], "Kilter 40°"),
    list("routes", [row("r1", "Crimp Theory", "V5 · 412 sends", "★ 3.1", { badge: { text: "V5", tone: "mute" }, accessory: "chevron" }), row("r2", "Pocket Rocket", "V4 · 1.2k sends", "Sent", { badge: { text: "V4", tone: "mute" }, accessory: "chevron" }), row("r3", "Night Shift", "V6 · 96 sends", "Project", { badge: { text: "V6", tone: "warn" }, accessory: "chevron" }), row("r4", "Lunar Lip", "V3 · 3.4k sends", "", { badge: { text: "V3", tone: "mute" }, accessory: "chevron" })]),
    btn("shot", "Add from a screenshot", "plain"),
  ] },

  route: { tab: "board", pushed: true, title: "Crimp Theory", back: "Board", blocks: [
    { type: "crag-board", id: "b", legend: true },
    stat("rs", [["V5", "Grade"], ["40°", "Angle"], ["412", "Sends"], ["3", "Your tries"]]),
    btn("light", "Light it up", "primary"), btn("log", "Log a send", "plain"),
  ] },

  force: { tab: "force", title: "Force", blocks: [
    chips("hand", "hand", ["Left", "Right", "Both"], "Right"),
    { type: "crag-curve", id: "c", title: "Max hang · live", sub: "20 mm edge", h: 150 },
    stat("fs", [["52.4", "Peak", "kg"], ["48.1", "Mean", "kg"], ["7.2", "Time", "s"], ["74%", "Bodyweight"]]),
    { type: "crag-roo", id: "pr", pose: "pr", size: 64, word: "PR!", wordSize: 30, line: "+1.8 kg on your best", row: true },
    btn("again", "Next rep", "primary"),
  ] },

  log: { tab: "log", title: "Log", blocks: [
    chips("rng", "rng", ["Week", "Month", "Year"], "Month"),
    stat("ls", [["14", "Sessions"], ["61", "Sends"], ["V6", "Top"], ["8", "Flashes"]]),
    { type: "chart", id: "g", chart: "bar", title: "Sends by grade", x: ["V2", "V3", "V4", "V5", "V6"], series: [{ name: "Sends", values: [14, 21, 15, 9, 2] }] },
    card("lb", "Logbook", "All ›", [ticks(3)]),
  ] },

  logbook: { tab: "log", pushed: true, title: "Logbook", back: "Log", blocks: [
    sec("d1", "Today · Pine Gully", [ticks(2)]),
    sec("d2", "Fri 20 Nov · Home board", [list("l2", [tick("a", "6B+", "Warm-up 3", "Home board", "Send", "ok"), tick("b", "6C", "Pinch Me", "Home board", "Whipper", "mute")])]),
    sec("d3", "14 Nov · Pine Gully", [list("l3", [tick("c", "V6", "Night Shift", "Pine Gully", "Project", "warn"), tick("d", "V3", "Lunar Lip", "Pine Gully", "Flash", "accent")])]),
  ] },

  settings: { tab: "today", pushed: true, title: "Settings", back: "Today", blocks: [
    sec("scene", "Scene", [chips("w", "weather", ["Live weather", "Clear", "Dawn", "Rain", "Fog"], "Live weather")], "Live weather follows your crag and the clock."),
    sec("look", "Look", [list("lk", [row("icon", "App icon", null, "Profile", { accessory: "chevron" }), row("units", "Units", null, "kg · V grades", { accessory: "chevron" })])]),
    sec("data", "Data", [list("dt", [row("hk", "Apple Health", null, "On", { accessory: "chevron" }), row("ic", "iCloud sync", null, "On", { accessory: "chevron" }), row("imp", "Bring over old data", null, "", { accessory: "chevron" })])]),
    sec("acct", "Account", [list("ac", [row("me", "guy@example.com", null, "", { accessory: "chevron" }), row("out", "Sign out", null, "", { style: "destructive" })])]),
  ] },

  appicon: { tab: "today", pushed: true, title: "App icon", back: "Settings", blocks: [{ type: "crag-icons", id: "ic" }] },

  pick: { tab: "board", pushed: true, title: "From a screenshot", back: "Board", blocks: [
    steps("st", ["Pick", "Check holds", "Save"], 0),
    { type: "crag-photo", id: "p", boxes: true },
    T("h", "Pick a screenshot of one route.", { tone: "mute" }),
    btn("choose", "Choose screenshot", "primary"),
  ] },
  check: { tab: "board", pushed: true, title: "Check holds", back: "Pick", blocks: [
    steps("st", ["Pick", "Check holds", "Save"], 1),
    { type: "crag-board", id: "b", legend: true, unsure: "5,3", rows: 11 },
    card("u", "1 hold unsure", "Tap to fix", [T("x", "F4 · hand or foot?")]),
    btn("ok", "Looks right", "primary"),
  ] },
  cantread: { tab: "board", pushed: true, title: "Can't read it", back: "Pick", blocks: [
    { type: "crag-roo", id: "m", pose: "shelter", size: 150, line: "No board found in this picture." },
    list("why", [row("a", "Crop to the board", null, ""), row("b", "Turn the lights on in the app", null, ""), row("c", "Use the app's share image", null, "")]),
    btn("again", "Try another", "primary"), btn("hand", "Set holds by hand", "plain"),
  ] },

  boardsetup: { tab: "board", pushed: true, title: "Add a board", back: "Board", blocks: [
    steps("st", ["Board", "Wiring", "Routes"], 0),
    { type: "form", id: "f", fields: [{ label: "Name", name: "n", type: "text", value: "Home" }, { label: "Angle", name: "a", type: "text", value: "40°" }, { label: "LED lights", name: "l", type: "toggle", value: true }] },
    chips("layout", "layout", ["Kilter", "Moon", "Tension", "Custom"], "Kilter"),
    btn("next", "Next", "primary"),
  ] },
  wiring: { tab: "board", pushed: true, title: "Wiring check", back: "Add a board", blocks: [
    steps("st", ["Board", "Wiring", "Routes"], 1),
    { type: "crag-board", id: "b", holds: { "0,0": "#4DA8FF", "8,0": "#4DA8FF", "0,11": "#4DA8FF", "8,11": "#4DA8FF", "4,5": "#43D17A" }, rows: 12 },
    card("q", "Step 2 of 3", null, [T("x", "Do the four corners light up?")]),
    btn("yes", "Yes", "primary"), btn("no", "No, fix it", "plain"),
  ] },
  boardimport: { tab: "board", pushed: true, title: "Import routes", back: "Board", blocks: [
    steps("st", ["Board", "Wiring", "Routes"], 2),
    list("f", [row("a", "kilter-home.db", "2.4 MB · 3,112 routes", "", { badge: { text: "DB", tone: "mute" } })]),
    stat("i", [["3,112", "Routes"], ["28", "Already here"], ["0", "Errors"]]),
    btn("go", "Import 3,084 routes", "primary"),
  ] },

  dataimport: { tab: "today", pushed: true, title: "Bring over old data", back: "Settings", blocks: [
    list("src", [row("a", "Sendmeter web export", "sendmeter-2025.json", "Found", { badge: { text: "JSON", tone: "mute" } }), row("b", "Apple Health", "Weight, HRV, sleep", "Allowed")]),
    stat("n", [["1,204", "Ticks"], ["186", "Sessions"], ["42", "Force tests"]]),
    btn("go", "Bring it over", "primary"),
  ] },
  sync: { tab: "today", pushed: true, title: "iCloud sync", back: "Settings", blocks: [
    { type: "form", id: "f", fields: [{ label: "Sync with iCloud", name: "on", type: "toggle", value: true }] },
    stat("s", [["Just now", "Last sync"], ["3", "Devices"]]),
    list("d", [row("a", "iPhone", "This device", "Synced"), row("b", "Apple Watch", null, "Synced"), row("c", "iPad", null, "2 h ago")]),
    btn("now", "Sync now", "plain"),
  ] },

  empty: { tab: "log", title: "Log", blocks: [
    { type: "crag-roo", id: "m", pose: "rest", size: 190, word: "No ticks yet", wordSize: 30, line: "Your first session shows up here." },
    btn("start", "Start session", "primary"),
  ] },
  error: { tab: "force", title: "Force", blocks: [
    { type: "crag-roo", id: "m", pose: "fall", size: 190, word: "Gauge not found", wordSize: 30, line: "Turn the Progressor on and hold it close." },
    btn("again", "Try again", "primary"), btn("help", "Pairing help", "plain"),
  ] },
  firstrun: { tab: "today", pushed: true, title: "", blocks: [
    { type: "crag-roo", id: "m", pose: "chalk", size: 200, word: "Sendmeter", wordSize: 42, line: "Log every climb. See what makes you send." },
    list("p", [row("a", "Apple Health", "Recovery from HRV and sleep", "Allow"), row("b", "Location", "Weather at your crag", "Allow"), row("c", "Bluetooth", "Tindeq force gauge", "Later")]),
    btn("go", "Get started", "primary"),
  ] },
};
