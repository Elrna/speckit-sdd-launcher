// SDD Launcher フロントエンド
// withGlobalTauri: true なので window.__TAURI__ から API を利用する。
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

let selectedDir = null;
let prereqs = { git: null, uv: null, claude: null };
let running = false;

// --- DOM ---
const els = {};
function $(id) {
  return document.getElementById(id);
}

// --- 前提条件チェック ---
async function checkPrereqs() {
  setNote("");
  for (const key of ["git", "uv", "claude"]) setDot(key, "pending", "確認中…");
  try {
    prereqs = await invoke("check_prerequisites");
  } catch (e) {
    setNote(`前提条件チェックに失敗: ${e}`, true);
    return;
  }
  for (const key of ["git", "uv", "claude"]) {
    const ver = prereqs[key];
    if (ver) setDot(key, "ok", ver);
    else setDot(key, "ng", "未検出");
  }

  // uv が無ければインストールボタンを出す
  els.installUv.classList.toggle("hidden", !!prereqs.uv);

  const notes = [];
  if (!prereqs.uv)
    notes.push("uv が未検出です。「uv をインストール」を押すか、手動で導入してください。");
  if (!prereqs.git)
    notes.push("git が未検出です。Spec-Kit の初期化には git を推奨します。");
  if (!prereqs.claude)
    notes.push("claude (Claude Code CLI) が未検出です。/SDD の実行には Claude Code が必要です。");
  setNote(notes.join(" "), notes.length > 0);

  refreshSetupButton();
}

function setDot(key, state, text) {
  const li = document.querySelector(`#prereq-list li[data-key="${key}"]`);
  if (!li) return;
  const dot = li.querySelector(".dot");
  dot.className = `dot ${state}`;
  li.querySelector(".ver").textContent = text;
}

function setNote(text, warn = false) {
  els.note.textContent = text;
  els.note.classList.toggle("warn", warn);
}

// --- フォルダ選択 ---
async function pickDir() {
  const dir = await invoke("pick_directory");
  if (dir) {
    selectedDir = dir;
    els.dirInput.value = dir;
    refreshSetupButton();
  }
}

function refreshSetupButton() {
  // uv が無い、フォルダ未選択、実行中はセットアップ不可
  els.setupBtn.disabled = running || !selectedDir || !prereqs.uv;
}

// --- ログ表示 ---
function appendLog(stream, line) {
  els.log.classList.remove("hidden");
  const span = document.createElement("span");
  span.className = `ln ${stream}`;
  span.textContent = line + "\n";
  els.log.appendChild(span);
  els.log.scrollTop = els.log.scrollHeight;
}

// --- uv インストール ---
async function installUv() {
  setBusy(true, "uv をインストール中…");
  els.log.classList.remove("hidden");
  try {
    const ver = await invoke("install_uv");
    appendLog("info", `uv インストール完了: ${ver}`);
    await checkPrereqs();
    setStatus(`uv を導入しました (${ver})`);
  } catch (e) {
    appendLog("stderr", String(e));
    setStatus(`uv のインストールに失敗: ${e}`, true);
  } finally {
    setBusy(false);
  }
}

// --- セットアップ実行 ---
async function runSetup() {
  if (!selectedDir) return;
  setBusy(true, "Spec-Kit を初期化中…");
  els.log.textContent = "";
  els.log.classList.remove("hidden");
  els.doneCard.classList.add("hidden");
  try {
    const msg = await invoke("run_setup", { dir: selectedDir });
    setStatus(msg);
    els.doneCard.classList.remove("hidden");
  } catch (e) {
    appendLog("stderr", String(e));
    setStatus(`セットアップに失敗: ${e}`, true);
  } finally {
    setBusy(false);
  }
}

function setBusy(b, statusText) {
  running = b;
  els.setupBtn.disabled = b || !selectedDir || !prereqs.uv;
  els.pickBtn.disabled = b;
  els.installUv.disabled = b;
  els.recheck.disabled = b;
  if (statusText) setStatus(statusText);
  refreshSetupButton();
}

function setStatus(text, err = false) {
  els.status.textContent = text;
  els.status.classList.toggle("err", err);
}

// --- 初期化 ---
window.addEventListener("DOMContentLoaded", async () => {
  els.note = $("prereq-note");
  els.installUv = $("install-uv-btn");
  els.recheck = $("recheck-btn");
  els.dirInput = $("dir-input");
  els.pickBtn = $("pick-btn");
  els.setupBtn = $("setup-btn");
  els.status = $("status");
  els.log = $("log");
  els.doneCard = $("done-card");

  els.pickBtn.addEventListener("click", pickDir);
  els.setupBtn.addEventListener("click", runSetup);
  els.installUv.addEventListener("click", installUv);
  els.recheck.addEventListener("click", checkPrereqs);

  // バックエンドからのログをストリーム表示
  await listen("setup-log", (e) => {
    const { stream, line } = e.payload;
    appendLog(stream, line);
  });

  await checkPrereqs();
});
