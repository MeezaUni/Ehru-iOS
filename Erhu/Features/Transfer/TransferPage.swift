import Foundation

/// The transfer page served to the computer's browser (the Android app's page, with the formats
/// iOS plays). Self-contained (inline CSS and JS, no external requests), so it works without
/// internet. It holds no secret: the session token comes from the QR link's #fragment (never sent
/// in the URL) or from typing the pairing code, and is kept in sessionStorage for this tab only.
/// File names are always inserted as text, never as HTML.
enum TransferPage {
    static let html = Data(source.utf8)

    private static let source = ##"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Erhu Wi-Fi Transfer</title>
<style>
:root { color-scheme: light dark; --bg:#f6f6f8; --card:#ffffff; --text:#17171c; --muted:#666a75; --accent:#d23c78; --ok:#2e7d32; --warn:#a15c00; --err:#c62828; --line:#e3e3ea; }
@media (prefers-color-scheme: dark) { :root { --bg:#111116; --card:#1c1c24; --text:#ececf2; --muted:#a0a3ad; --line:#2c2c37; --ok:#7bc47f; --warn:#e0a24a; --err:#ef7b7b; } }
* { box-sizing: border-box; }
body { margin:0; font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; background:var(--bg); color:var(--text); }
main { max-width:880px; margin:0 auto; padding:28px 20px 60px; }
h1 { font-size:22px; margin:0 0 4px; } .sub { color:var(--muted); margin:0 0 20px; }
.card { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:18px; margin-bottom:16px; }
.drop { border:2px dashed var(--line); border-radius:14px; padding:28px; text-align:center; color:var(--muted); }
.drop.over { border-color:var(--accent); color:var(--text); }
button { font:inherit; border:0; border-radius:999px; padding:9px 18px; cursor:pointer; background:var(--line); color:var(--text); }
button.primary { background:var(--accent); color:#fff; } button:disabled { opacity:.45; cursor:default; }
.row { display:flex; gap:10px; flex-wrap:wrap; align-items:center; justify-content:center; margin-top:12px; }
table { width:100%; border-collapse:collapse; font-size:14px; }
td { padding:8px 6px; border-top:1px solid var(--line); vertical-align:middle; }
td.name { word-break:break-all; } td.size { white-space:nowrap; color:var(--muted); width:90px; text-align:right; }
td.state { width:230px; } td.act { width:40px; text-align:right; }
.bar { height:6px; background:var(--line); border-radius:3px; overflow:hidden; margin-top:4px; } .bar i { display:block; height:100%; width:0; background:var(--accent); }
.ok { color:var(--ok); } .warn { color:var(--warn); } .err { color:var(--err); } .muted { color:var(--muted); }
input[type=text] { font:inherit; font-size:22px; letter-spacing:6px; width:9em; text-align:center; padding:8px; border-radius:10px; border:1px solid var(--line); background:var(--bg); color:var(--text); }
.hidden { display:none; } .summary { display:flex; gap:18px; flex-wrap:wrap; }
</style>
</head>
<body>
<main>
<h1>Erhu Wi-Fi Transfer</h1>
<p class="sub">Send music from this computer straight to your phone over your Wi-Fi. Nothing goes through the internet.</p>

<section id="pairCard" class="card hidden">
  <p>Enter the 6-digit code shown on the phone.</p>
  <div class="row"><input id="code" type="text" inputmode="numeric" maxlength="6" autocomplete="off"><button id="pairBtn" class="primary">Connect</button></div>
  <p id="pairMsg" class="row err"></p>
</section>

<section id="pickCard" class="card hidden">
  <div id="drop" class="drop">
    <div><b>Drop music files or folders here</b></div>
    <div class="muted">MP3, FLAC, M4A, AAC, WAV and AIFF</div>
    <div class="row">
      <button id="pickFiles">Choose files</button>
      <button id="pickFolder" class="hidden">Choose a folder</button>
    </div>
  </div>
  <input id="fileInput" type="file" multiple accept=".mp3,.flac,.m4a,.aac,.wav,.aif,.aiff,audio/*" class="hidden">
  <input id="folderInput" type="file" multiple class="hidden">
</section>

<section id="listCard" class="card hidden">
  <div class="summary">
    <span id="sumTotal"></span><span id="sumOk" class="ok"></span><span id="sumDup" class="warn"></span><span id="sumErr" class="err"></span>
  </div>
  <div class="bar"><i id="overall"></i></div>
  <div class="row">
    <button id="startBtn" class="primary">Send to phone</button>
    <button id="cancelAll">Cancel</button>
    <button id="clearBtn">Clear list</button>
  </div>
  <table><tbody id="rows"></tbody></table>
</section>
<p id="fatal" class="err"></p>
</main>
<script>
(function () {
  "use strict";
  var AUDIO = ["mp3","flac","m4a","aac","wav","aif","aiff"];
  var PARALLEL = 2;
  var token = null;
  var items = [];
  var running = 0;
  var sending = false;
  function el(id) { return document.getElementById(id); }
  function show(id, on) { el(id).classList.toggle("hidden", !on); }
  function ext(name) { var i = name.lastIndexOf("."); return i < 0 ? "" : name.slice(i + 1).toLowerCase(); }
  function human(n) { var u = ["B","KB","MB","GB"]; var i = 0; while (n >= 1024 && i < 3) { n /= 1024; i++; } return (i ? n.toFixed(1) : n) + " " + u[i]; }
  function headers(xhr) { xhr.setRequestHeader("X-Erhu-Transfer", "1"); if (token) xhr.setRequestHeader("X-Transfer-Token", token); }

  function readToken() {
    var m = /(?:^|[#&])t=([A-Za-z0-9_-]{20,})/.exec(location.hash);
    if (m) {
      token = m[1];
      try { sessionStorage.setItem("erhuToken", token); } catch (e) {}
      history.replaceState(null, "", location.pathname);
    } else {
      try { token = sessionStorage.getItem("erhuToken"); } catch (e) {}
    }
  }

  function setPaired(on) { show("pairCard", !on); show("pickCard", on); show("listCard", on && items.length > 0); }

  function pair() {
    var code = el("code").value.trim();
    var xhr = new XMLHttpRequest();
    xhr.open("POST", "/api/pair");
    headers(xhr);
    xhr.setRequestHeader("X-Pairing-Code", code);
    xhr.onload = function () {
      var r = parse(xhr);
      if (xhr.status === 200 && r.token) {
        token = r.token;
        try { sessionStorage.setItem("erhuToken", token); } catch (e) {}
        el("pairMsg").textContent = "";
        setPaired(true);
      } else {
        el("pairMsg").textContent = r.message || "Could not connect";
      }
    };
    xhr.onerror = function () { el("pairMsg").textContent = "The phone is not reachable. Is Wi-Fi Transfer still on?"; };
    xhr.send();
  }

  function parse(xhr) { try { return JSON.parse(xhr.responseText) || {}; } catch (e) { return {}; } }

  function add(files) {
    for (var i = 0; i < files.length; i++) {
      var f = files[i];
      var item = { file: f, name: f.name, size: f.size, state: "queued", sent: 0, xhr: null, tries: 0 };
      if (AUDIO.indexOf(ext(f.name)) < 0) { item.state = "skipped"; item.msg = "Not a supported audio file"; }
      else if (f.size === 0) { item.state = "skipped"; item.msg = "Empty file"; }
      items.push(item);
      row(item);
    }
    refresh();
  }

  function row(item) {
    var tr = document.createElement("tr");
    var name = document.createElement("td"); name.className = "name"; name.textContent = item.name;
    var size = document.createElement("td"); size.className = "size"; size.textContent = human(item.size);
    var state = document.createElement("td"); state.className = "state";
    var label = document.createElement("div"); var bar = document.createElement("div"); bar.className = "bar"; var fill = document.createElement("i"); bar.appendChild(fill);
    state.appendChild(label); state.appendChild(bar);
    var act = document.createElement("td"); act.className = "act";
    var x = document.createElement("button"); x.textContent = "×"; x.title = "Cancel or remove"; x.setAttribute("aria-label", "Cancel or remove " + item.name);
    x.onclick = function () { cancel(item); };
    act.appendChild(x);
    tr.appendChild(name); tr.appendChild(size); tr.appendChild(state); tr.appendChild(act);
    el("rows").appendChild(tr);
    item.ui = { tr: tr, label: label, fill: fill, x: x };
    paint(item);
  }

  var LABELS = { queued: ["Waiting", "muted"], checking: ["Checking", "muted"], sending: ["Sending", ""], saving: ["Saving on phone", ""],
    saved: ["Saved", "ok"], duplicate: ["Already on phone", "warn"], skipped: ["Skipped", "warn"], failed: ["Failed", "err"], cancelled: ["Cancelled", "muted"] };

  function paint(item) {
    var l = LABELS[item.state];
    var text = l[0];
    if (item.state === "sending") text += " " + Math.floor(100 * item.sent / Math.max(1, item.size)) + "%";
    if (item.msg && (item.state === "failed" || item.state === "skipped" || item.state === "duplicate")) text += " - " + item.msg;
    item.ui.label.textContent = text;
    item.ui.label.className = l[1];
    var pct = item.state === "saved" || item.state === "saving" ? 100 : Math.floor(100 * item.sent / Math.max(1, item.size));
    item.ui.fill.style.width = pct + "%";
  }

  function done(item) { return ["saved","duplicate","skipped","failed","cancelled"].indexOf(item.state) >= 0; }

  function refresh() {
    var total = 0, sent = 0, ok = 0, dup = 0, err = 0;
    items.forEach(function (it) {
      if (it.state === "skipped" || it.state === "cancelled") { if (it.state === "skipped") err++; return; }
      total += it.size; sent += (it.state === "saved" || it.state === "duplicate") ? it.size : it.sent;
      if (it.state === "saved") ok++; if (it.state === "duplicate") dup++; if (it.state === "failed") err++;
    });
    el("sumTotal").textContent = items.length + " file" + (items.length === 1 ? "" : "s");
    el("sumOk").textContent = ok ? ok + " saved" : "";
    el("sumDup").textContent = dup ? dup + " already on phone" : "";
    el("sumErr").textContent = err ? err + " not sent" : "";
    el("overall").style.width = (total ? Math.floor(100 * sent / total) : 0) + "%";
    var pending = items.some(function (it) { return it.state === "queued"; });
    el("startBtn").disabled = sending || !pending;
    el("cancelAll").disabled = !sending;
    el("clearBtn").disabled = sending;
    show("listCard", items.length > 0);
  }

  function start() { sending = true; pump(); refresh(); }

  function pump() {
    if (!sending) return;
    while (running < PARALLEL) {
      var next = items.find(function (it) { return it.state === "queued"; });
      if (!next) break;
      running++;
      check(next);
    }
    if (running === 0) { sending = false; refresh(); }
  }

  function finish(item, state, msg) {
    if (done(item)) return;
    item.state = state; item.msg = msg || item.msg; item.xhr = null;
    paint(item); running--; refresh(); pump();
  }

  function check(item) {
    item.state = "checking"; paint(item);
    var xhr = new XMLHttpRequest(); item.xhr = xhr;
    xhr.open("POST", "/api/check");
    headers(xhr);
    xhr.setRequestHeader("X-File-Name", encodeURIComponent(item.name));
    xhr.setRequestHeader("X-File-Size", String(item.size));
    xhr.onload = function () {
      var r = parse(xhr);
      if (xhr.status === 200 && r.status === "ok") { upload(item); }
      else if (xhr.status === 200 && r.status === "duplicate") { finish(item, "duplicate", r.message); }
      else if (xhr.status === 401) { lost(r.message); finish(item, "failed", r.message); }
      else { finish(item, "failed", r.message || ("Error " + xhr.status)); }
    };
    xhr.onerror = function () { finish(item, "failed", "The phone is not reachable"); };
    xhr.send();
  }

  function upload(item) {
    item.state = "sending"; item.sent = 0; paint(item);
    var xhr = new XMLHttpRequest(); item.xhr = xhr;
    xhr.open("POST", "/api/upload");
    headers(xhr);
    xhr.setRequestHeader("X-File-Name", encodeURIComponent(item.name));
    xhr.setRequestHeader("Content-Type", "application/octet-stream");
    xhr.upload.onprogress = function (e) { if (e.lengthComputable) { item.sent = e.loaded; paint(item); refresh(); } };
    xhr.upload.onload = function () { if (!done(item)) { item.state = "saving"; paint(item); } };
    xhr.onload = function () {
      var r = parse(xhr);
      if (xhr.status === 200 && r.status === "saved") { item.sent = item.size; finish(item, "saved"); }
      else if (xhr.status === 200 && r.status === "duplicate") { finish(item, "duplicate", r.message); }
      else if (xhr.status === 429 && item.tries < 5) { item.tries++; item.state = "queued"; item.xhr = null; running--; paint(item); setTimeout(pump, 1500); }
      else if (xhr.status === 401) { lost(r.message); finish(item, "failed", r.message); }
      else { finish(item, "failed", r.message || ("Error " + xhr.status)); }
    };
    xhr.onerror = function () { finish(item, "failed", "Connection lost: is the phone still on this Wi-Fi?"); };
    xhr.onabort = function () { finish(item, "cancelled"); };
    xhr.send(item.file);
  }

  function cancel(item) {
    if (item.xhr) { item.xhr.abort(); return; }
    if (!done(item) && item.state === "queued") { item.state = "cancelled"; paint(item); refresh(); return; }
    if (done(item) && !sending) { item.ui.tr.remove(); items.splice(items.indexOf(item), 1); refresh(); }
  }

  function cancelAll() {
    sending = false;
    items.forEach(function (it) { if (it.state === "queued") { it.state = "cancelled"; paint(it); } });
    items.forEach(function (it) { if (it.xhr) it.xhr.abort(); });
    refresh();
  }

  function lost(message) {
    sending = false;
    token = null;
    try { sessionStorage.removeItem("erhuToken"); } catch (e) {}
    el("fatal").textContent = message || "This transfer session has ended. Start Wi-Fi Transfer on the phone again.";
  }

  function readEntries(entry, out, then) {
    if (entry.isFile) { entry.file(function (f) { out.push(f); then(); }, then); return; }
    if (!entry.isDirectory) { then(); return; }
    var reader = entry.createReader(), all = [];
    (function batch() {
      reader.readEntries(function (list) {
        if (!list.length) {
          var left = all.length; if (!left) { then(); return; }
          all.forEach(function (child) { readEntries(child, out, function () { if (--left === 0) then(); }); });
        } else { all = all.concat(Array.prototype.slice.call(list)); batch(); }
      }, then);
    })();
  }

  function setup() {
    readToken();
    setPaired(!!token);
    el("pairBtn").onclick = pair;
    el("code").addEventListener("keydown", function (e) { if (e.key === "Enter") pair(); });
    el("pickFiles").onclick = function () { el("fileInput").click(); };
    el("fileInput").onchange = function () { add(this.files); this.value = ""; };
    var folder = el("folderInput");
    if ("webkitdirectory" in folder) {
      folder.webkitdirectory = true;
      show("pickFolder", true);
      el("pickFolder").onclick = function () { folder.click(); };
      folder.onchange = function () { add(this.files); this.value = ""; };
    }
    var drop = el("drop");
    ["dragenter", "dragover"].forEach(function (t) { drop.addEventListener(t, function (e) { e.preventDefault(); drop.classList.add("over"); }); });
    ["dragleave", "drop"].forEach(function (t) { drop.addEventListener(t, function (e) { e.preventDefault(); drop.classList.remove("over"); }); });
    drop.addEventListener("drop", function (e) {
      var dt = e.dataTransfer;
      var entries = dt.items && dt.items.length && dt.items[0].webkitGetAsEntry ? Array.prototype.map.call(dt.items, function (i) { return i.webkitGetAsEntry(); }).filter(Boolean) : null;
      if (!entries) { add(dt.files); return; }
      var out = [], left = entries.length;
      entries.forEach(function (en) { readEntries(en, out, function () { if (--left === 0) add(out); }); });
    });
    el("startBtn").onclick = start;
    el("cancelAll").onclick = cancelAll;
    el("clearBtn").onclick = function () { items = []; el("rows").textContent = ""; refresh(); };
    window.addEventListener("beforeunload", function (e) { if (sending) { e.preventDefault(); e.returnValue = ""; } });
    refresh();
  }
  setup();
})();
</script>
</body>
</html>
"""##
}
