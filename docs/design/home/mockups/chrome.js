// Builds the window frame shared by every mockup: the sidebar, toolbar and
// the theme wallpaper. `?theme=<id>` overrides the page's data-theme.
// All people, channels and messages are fictional.

(function () {
  // ---------- icons (SF Symbol look-alikes) ----------
  const icon = {
    compose: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M9 4H5.5A1.5 1.5 0 0 0 4 5.5v9A1.5 1.5 0 0 0 5.5 16h9a1.5 1.5 0 0 0 1.5-1.5V11"/><path d="M14.5 3.5l2 2L10 12l-2.7.7.7-2.7z"/></svg>',
    tray: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M3 11l2-6.5h10L17 11v4.5H3z"/><path d="M3 11h4l1 2h4l1-2h4"/></svg>',
    threads: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M3 5h9v6H7l-3 2.5V11H3z"/><path d="M14 8h3v6h-1v2l-2.5-2H9.5v-1.5"/></svg>',
    bookmark: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M6 3.5h8v13l-4-3-4 3z"/></svg>',
    search: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14"/></svg>',
    sidebar: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="4" width="14" height="12" rx="2.5"/><path d="M8 4v12"/></svg>',
    house: '<svg viewBox="0 0 20 20" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><path d="M3.5 9.5L10 4l6.5 5.5"/><path d="M5.5 8.5v7.5h9V8.5"/></svg>',
  };
  window.ICON = icon;

  // ---------- people and channels ----------
  const people = {
    mara: { name: "Mara Lindqvist", initials: "ML", c: 0, active: true },
    tomas: { name: "Tomás Ferreira", initials: "TF", c: 1, active: true },
    aiko: { name: "Aiko Tanaka", initials: "AT", c: 2, active: true },
    jonas: { name: "Jonas Weber", initials: "JW", c: 3, active: false },
    priya: { name: "Priya Raman", initials: "PR", c: 4, active: true },
    lea: { name: "Léa Martin", initials: "LM", c: 5, active: false, away: true },
    sam: { name: "Sam O'Neill", initials: "SO", c: 1, active: false },
  };
  window.PEOPLE = people;
  window.avatar = function (key, size, opts) {
    const p = people[key];
    const showDot = (opts && opts.dot === false) ? false : (p.active || p.away);
    const dot = showDot ? `<span class="dot${p.away ? " away" : ""}"></span>` : "";
    return `<span class="av s${size} c${p.c}">${p.initials}${dot}</span>`;
  };

  // The app's unread raven (RavenGlyph.swift), ported to SVG with y flipped:
  // a 16 x 14 box, facing left, feet on the bottom edge.
  window.raven = function (o) {
    o = o || {};
    const ink = o.ink || "currentColor", eye = o.eye || "rgba(255,255,255,.85)";
    const head = o.glance ? ` transform="rotate(${o.glance} 6.2 5)"` : "";
    if (o.flying) {
      return `<svg viewBox="0 0 16 14" width="${o.w || 16}" height="${(o.w || 16) * 14 / 16}" style="${o.style || ""}" aria-hidden="true">
        <path d="M3.8 6.9C5.4 5.5 8.8 5.7 11 6.3L16 5.9 15.7 7.8C10.6 8.1 5.6 8.8 3.8 6.9Z" style="fill:${ink}"/>
        <path d="M5.8 6.6Q7 1.6 12.2 .2Q11.4 3.8 11.2 6.8Z" style="fill:${ink}"/>
        <g transform="translate(-1.1 3.3)"><ellipse cx="5.65" cy="3.45" rx="2.15" ry="2.05" style="fill:${ink}"/><path d="M4.3 1.9C2.9 2 1.4 2.9.5 4.2L3.8 4.8Z" style="fill:${ink}"/><circle cx="4.9" cy="3" r=".5" style="fill:${eye}"/></g></svg>`;
    }
    return `<svg viewBox="0 0 16 14" width="${o.w || 16}" height="${(o.w || 16) * 14 / 16}" style="${o.style || ""}" aria-hidden="true">
      <path d="M7.6 10.5L7.3 13.65H6.2M9.3 10.6L9.2 13.65H8.1" style="stroke:${ink};fill:none" stroke-width=".7" stroke-linecap="round"/>
      <path d="M4.7 7C4.9 5.3 6.2 4.3 7.7 4.3C9.6 4.3 11 6.4 12.1 8L15.9 11.3 15.1 12.3C12.9 11 10.8 10.8 9 10.8C6.6 10.8 4.5 9.4 4.7 7Z" style="fill:${ink}"/>
      <g${head}><ellipse cx="5.65" cy="3.45" rx="2.15" ry="2.05" style="fill:${ink}"/><path d="M4.3 1.9C2.9 2 1.4 2.9.5 4.2L3.8 4.8Z" style="fill:${ink}"/><circle cx="4.9" cy="3" r="${o.lit ? .8 : .5}" style="fill:${eye}"/></g></svg>`;
  };

  document.addEventListener("DOMContentLoaded", buildFrame);
  function buildFrame() {
  const params = new URLSearchParams(location.search);
  if (params.get("theme")) document.body.dataset.theme = params.get("theme");
  if (params.get("pop")) document.body.classList.add("show-pop");
  const theme = document.body.dataset.theme;
  if (theme === "nevermore" || theme === "synthwave") document.body.classList.add("dark-desk");
  const homeLabel = document.body.dataset.home || "Home";
  const rows = [
    { kind: "home" },
    { head: "Favorites" },
    { chan: "design", count: 3 },
    { dm: "mara", count: 2 },
    { head: "Studio" },
    { chan: "general", count: 1 },
    { chan: "releases", count: 5 },
    { chan: "support", count: 12, muted: true },
    { chan: "random" },
    { head: "Direct Messages" },
    { dm: "tomas", count: 1 },
    { dm: "aiko" },
    { dm: "jonas" },
    { dm: "priya" },
    { dm: "lea" },
  ];
  // The zero-unread mockups show a sidebar with nothing new except muted channels.
  if (document.body.hasAttribute("data-caught-up")) rows.forEach((r) => { if (!r.muted) delete r.count; });
  const sideHTML = rows.map((r) => {
    if (r.kind === "home") return `<div class="side-row sel"><span class="glyph">${icon.house}</span><span class="name">${homeLabel}</span></div>`;
    if (r.head) return `<div class="side-head">${r.head}</div>`;
    const unread = r.count && !r.muted ? " unread" : "";
    const count = r.count ? `<span class="count">${r.count}</span>` : "";
    const mute = r.muted ? `<span class="mute">🔕</span>` : "";
    if (r.chan) return `<div class="side-row${unread}"><span class="glyph">#</span><span class="name">${r.chan}</span>${mute}${count}</div>`;
    return `<div class="side-row${unread}"><span class="glyph">${avatar(r.dm, 18)}</span><span class="name">${people[r.dm].name}</span>${count}</div>`;
  }).join("");

  const sidebar = document.querySelector(".sidebar");
  if (sidebar) sidebar.innerHTML = `<div class="lights"><i></i><i></i><i></i></div>${sideHTML}<div class="side-spacer"></div>`;

  const toolbar = document.querySelector(".toolbar");
  if (toolbar && !toolbar.innerHTML.trim()) {
    toolbar.innerHTML = `
      <div><div class="title">${homeLabel}</div><div class="subtitle">Studio · chat.example.org</div></div>
      <div class="grow"></div>
      <div class="glass tool-group"><b>${icon.compose}</b><b>${icon.tray}</b><b>${icon.threads}</b><b>${icon.bookmark}</b></div>
      <div class="glass search">${icon.search}<span>Search</span></div>`;
  }

  // ---------- wallpaper ----------
  const motifPaths = {
    triangle: { d: '<polygon points="12,3 21.5,19.5 2.5,19.5" fill="none" stroke="C" stroke-width="2.2" stroke-linejoin="round"/>' },
    diamond: { d: '<polygon points="6.5,4 17.5,4 22,9.5 12,21 2,9.5" fill="C"/>' },
    sparkle: { d: '<path d="M12 2C12.8 9 15 11.2 22 12 15 12.8 12.8 15 12 22 11.2 15 9 12.8 2 12 9 11.2 11.2 9 12 2Z" fill="C"/>' },
    dot: { d: '<circle cx="12" cy="12" r="6" fill="C"/>' },
    star: { d: '<polygon points="12,2.5 14.6,9 21.5,9.3 16.1,13.6 18,20.5 12,16.6 6,20.5 7.9,13.6 2.5,9.3 9.4,9" fill="C"/>' },
    raven: { d: '<path d="M2.5 15.5C5.5 11.6 9 10.4 12.2 11l2.2-3.6 3-.9 2 .7 2.1-.2-1.8 1.5c.2 2.6-1.6 5-4.6 6l2 4.3-3.3-3.3-3.4 3.4.9-3.8C7.5 15.9 4.8 16.2 2.5 15.5Z" fill="C"/>' },
    feather: { d: '<path d="M19 3C10.5 4.6 6.2 10.6 5.2 19.6l1.2 1C8.2 13.8 11.6 8.6 19 3Z M7.4 15.5c3.2-.4 6.2-2.2 8.3-5.6" fill="C" stroke="C" stroke-width=".6"/>' },
    sun: { d: '<circle cx="12" cy="12" r="5.5" fill="C"/><g stroke="C" stroke-width="2" stroke-linecap="round"><path d="M12 1.5v3M12 19.5v3M1.5 12h3M19.5 12h3M4.6 4.6l2.1 2.1M17.3 17.3l2.1 2.1M4.6 19.4l2.1-2.1M17.3 6.7l2.1-2.1"/></g>' },
  };
  const themes = {
    classic: null,
    vaporwave: { count: 30, motifs: [["triangle", ["#FF6AD5", "#94D0FF"], 3], ["diamond", ["#AD8CFF", "#FF6AD5"], 2], ["sparkle", ["#FFFFFF"], 2], ["dot", ["#C774E8", "#8795E8"], 2]], ornament: "vapor" },
    nevermore: { count: 16, motifs: [["raven", ["#5A4B70"], 3], ["feather", ["#6B5A80", "#4E4262"], 3], ["star", ["#A07C33"], 1], ["sparkle", ["#B8A57A"], 1]], ornament: "moon" },
    synthwave: { count: 18, motifs: [["star", ["#FFD35C", "#FF9EDB"], 2], ["sparkle", ["#FFFFFF", "#5CE1FF"], 2], ["dot", ["#C68BFF"], 1]], ornament: "synth" },
  };
  const spec = themes[theme];
  const wall = document.querySelector(".wallpaper");
  if (spec && wall && !document.body.hasAttribute("data-no-wall")) {
    let seed = 7;
    const rand = () => { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; };
    const bag = [];
    spec.motifs.forEach(([kind, colors, weight]) => { for (let i = 0; i < weight; i++) bag.push([kind, colors]); });
    const op = getComputedStyle(document.body).getPropertyValue("--wall-opacity").trim();
    let html = "";
    const cols = 6, rowsN = Math.ceil(spec.count / cols);
    for (let i = 0; i < spec.count; i++) {
      const [kind, colors] = bag[Math.floor(rand() * bag.length)];
      const color = colors[Math.floor(rand() * colors.length)];
      const cx = (i % cols + 0.15 + rand() * 0.7) / cols * 1280;
      const cy = (Math.floor(i / cols) + 0.1 + rand() * 0.8) / rowsN * 800;
      const size = 16 + rand() * 22;
      const rot = Math.floor(rand() * 60 - 30);
      html += `<svg class="motif" viewBox="0 0 24 24" style="left:${cx}px;top:${cy}px;width:${size}px;height:${size}px;opacity:${op};transform:rotate(${rot}deg)">${motifPaths[kind].d.replaceAll("C\"", color + "\"")}</svg>`;
    }
    if (spec.ornament === "vapor" || spec.ornament === "synth") {
      const [a, b, grid, o1, o2] = spec.ornament === "vapor" ? ["#FF6AD5", "#FFB8E8", "#C774E8", 0.24, 0.3] : ["#FFD35C", "#FB1A91", "#FB1A91", 0.15, 0.18];
      let lines = "";
      for (let x = -12; x <= 12; x++) lines += `<line x1="${640 + x * 30}" y1="0" x2="${640 + x * 150}" y2="190" />`;
      for (let k = 1; k <= 7; k++) { const y = 190 * Math.pow(k / 7, 1.9); lines += `<line x1="0" y1="${y}" x2="1280" y2="${y}" />`; }
      let stripes = "";
      for (let k = 0; k < 6; k++) stripes += `<rect x="440" y="${70 + k * 18}" width="400" height="${3 + k * 1.6}" fill="black"/>`;
      html += `<svg class="ornament" viewBox="0 0 1280 330" width="1280" height="330" style="height:330px">
        <defs><linearGradient id="sg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient>
        <mask id="sm"><rect width="1280" height="330" fill="white"/>${stripes}</mask></defs>
        <circle cx="640" cy="230" r="190" fill="url(#sg)" opacity="${o1}" mask="url(#sm)"/>
        <g transform="translate(0,140)" stroke="${grid}" stroke-width="1.2" opacity="${o2}">${lines}</g></svg>`;
    }
    if (spec.ornament === "moon") {
      html += `<svg style="position:absolute;right:40px;top:30px;width:150px;height:150px;opacity:.11" viewBox="0 0 100 100"><defs><mask id="mm"><rect width="100" height="100" fill="white"/><circle cx="66" cy="38" r="38" fill="black"/></mask></defs><circle cx="50" cy="50" r="42" fill="#EFE6D8" mask="url(#mm)"/></svg>`;
    }
    wall.innerHTML = html;
  }
  }
})();
