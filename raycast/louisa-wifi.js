#!/usr/bin/osascript -l JavaScript

// Required parameters:
// @raycast.schemaVersion 1
// @raycast.title Louisa Wi-Fi
// @raycast.mode compact
// @raycast.argument1 { "type": "text", "placeholder": "門市或地址（留空連最近門市）", "optional": true }

// Optional parameters:
// @raycast.icon ☕️
// @raycast.packageName Louisa Wi-Fi
// @raycast.description 連上路易莎門市的 Wi-Fi

// With the LouisaWiFi app installed, this hands the work to the app (it has
// Location permission, knows the nearest store and remembers routers).
// Without it, it connects by itself using networksetup; you just have to name the store.

ObjC.import('Foundation')
ObjC.import('AppKit')

const REPO = 'PipperL/louisa-wifi'
const SSID = 'LouisaCoffee'
const HOME = $.NSHomeDirectory().js
const STATUS = `${HOME}/Library/Application Support/LouisaWiFi/status.json`
const CACHE = `${HOME}/Library/Caches/louisa-wifi/stores.json`

const app = Application.currentApplication()
app.includeStandardAdditions = true

function run(argv) {
  const keyword = (argv[0] || '').trim()
  const appPath = findApp()
  const stores = loadStores(appPath)
  if (!stores) return '❌ 無法讀取門市資料（首次使用需要網路連線）'

  if (!keyword) {
    if (!appPath) return '尚未安裝 Louisa Wi-Fi，請輸入門市名稱或地址'
    return viaApp('louisawifi://nearest')
  }

  const store = pick(search(stores, keyword), keyword)
  if (store === undefined) return `❌ 找不到符合「${keyword}」的門市`
  if (store === null) return '已取消'

  return appPath
    ? viaApp(`louisawifi://connect?store=${encodeURIComponent(store.name)}`)
    : standalone(store)
}

// MARK: - Stores

function findApp() {
  // Whatever app handles louisawifi:// is the one we'd be talking to anyway.
  const url = $.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL($.NSURL.URLWithString('louisawifi://nearest'))
  if (!url.isNil()) return url.path.js
  for (const p of ['/Applications/LouisaWiFi.app', `${HOME}/Applications/LouisaWiFi.app`]) {
    if (exists(p)) return p
  }
  return null
}

function loadStores(appPath) {
  if (appPath) return JSON.parse(read(`${appPath}/Contents/Resources/stores.json`))
  const weekOld = sh(`find ${q(CACHE)} -mtime -7 2>/dev/null || true`) === ''
  if (weekOld) {
    try {
      sh(`mkdir -p ${q(CACHE.replace(/\/[^/]+$/, ''))} && curl -fsSL --max-time 10 -o ${q(CACHE + '.tmp')} https://raw.githubusercontent.com/${REPO}/data/data/stores.json && mv ${q(CACHE + '.tmp')} ${q(CACHE)}`)
    } catch (e) {} // offline: fall back to the cached copy
  }
  return exists(CACHE) ? JSON.parse(read(CACHE)) : null
}

/** Every word must appear in the name or address: "大安 復興" works. */
function search(stores, keyword) {
  const exact = stores.filter(s => s.name === keyword || s.name === `${keyword}門市`)
  if (exact.length) return exact
  const words = keyword.toLowerCase().split(/\s+/)
  return stores.filter(s => words.every(w => `${s.name} ${s.address}`.toLowerCase().includes(w)))
}

/** undefined = nothing matched, null = user cancelled. */
function pick(matches, keyword) {
  if (matches.length <= 1) return matches[0]
  const labels = matches.map(s => `${s.name}　${s.address}`)
  const se = Application('System Events')
  se.includeStandardAdditions = true
  se.activate()
  const choice = se.chooseFromList(labels, {
    withTitle: '路易莎 Wi-Fi',
    withPrompt: `找到 ${matches.length} 家符合「${keyword}」的門市，請選擇：`,
    defaultItems: [labels[0]],
  })
  return choice ? matches[labels.indexOf(choice[0])] : null
}

// MARK: - Connect

/** Ask the app to connect and wait for its answer in status.json. */
function viaApp(url) {
  const start = Date.now() / 1000
  sh(`open -g ${q(url)}`)
  for (let i = 0; i < 180; i++) {
    delay(0.5)
    if (!exists(STATUS)) continue
    const s = JSON.parse(read(STATUS))
    if (s.time >= start && s.state !== 'connecting') return (s.state === 'connected' ? '✅ ' : '⚠️ ') + s.message
  }
  return '⚠️ 等待逾時，請從選單列的 ☕ 查看連線狀態'
}

function standalone(store) {
  const dev = sh("networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2; exit}'") || 'en0'
  sh(`networksetup -setairportpower ${dev} on`)
  for (const pw of store.passwords) {
    let out
    try { out = sh(`networksetup -setairportnetwork ${dev} ${SSID} ${q(pw)} 2>&1`) } catch (e) { out = String(e) }
    if (/could not find/i.test(out)) return '❌ 附近找不到路易莎 Wi-Fi'
    if (!out.trim() && online(10)) return `✅ 已連上：${store.name}`
  }
  return `❌ 無法連上${store.name}，請確認門市與密碼`
}

function online(seconds) {
  for (let i = 0; i < seconds; i++) {
    try {
      if (sh('curl -s --max-time 2 http://captive.apple.com/hotspot-detect.html').includes('Success')) return true
    } catch (e) {}
    delay(1)
  }
  return false
}

// MARK: - Helpers

function sh(cmd) { return app.doShellScript(cmd).trim() }
function q(s) { return `'${String(s).replace(/'/g, `'\\''`)}'` }
function exists(p) { return $.NSFileManager.defaultManager.fileExistsAtPath(p) }
function read(p) { return $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null).js }
