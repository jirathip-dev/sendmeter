const dir = new URLSearchParams(location.search).get("d") || "chalk";
document.documentElement.dataset.dir = dir;

for (const svg of document.querySelectorAll("svg.spark")) {
  const v = svg.dataset.v.split(",").map(Number);
  const lo = Math.min(...v), hi = Math.max(...v);
  const pts = v.map((y, i) => `${(i / (v.length - 1)) * 100},${22 - ((y - lo) / (hi - lo || 1)) * 18}`);
  svg.setAttribute("viewBox", "0 0 100 26");
  svg.setAttribute("preserveAspectRatio", "none");
  svg.innerHTML = `<polyline points="${pts.join(" ")}" vector-effect="non-scaling-stroke"/>`;
}

for (const svg of document.querySelectorAll("svg.wall")) {
  const cols = 11, rows = 12, gap = 30;
  const holds = JSON.parse(svg.dataset.holds);
  const lit = new Map(holds.map(([c, r, role]) => [`${c},${r}`, role]));
  svg.setAttribute("viewBox", `0 0 ${cols * gap} ${rows * gap}`);
  let out = "";
  for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
    const x = c * gap + gap / 2, y = r * gap + gap / 2;
    const size = 3 + ((c * 7 + r * 5) % 4) * 1.6;
    out += `<circle class="hold-dot" cx="${x}" cy="${y}" r="${size}"/>`;
    const role = lit.get(`${c},${r}`);
    if (role) out += `<circle class="hold ${role}" cx="${x}" cy="${y}" r="11"/>`;
  }
  svg.innerHTML = out;
}
