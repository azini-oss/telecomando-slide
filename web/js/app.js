// Collega interfaccia, protocollo e Bluetooth (o la demo).
import { createBleTransport, isBluetoothSupported } from './ble.js';
import { createDemoTransport } from './demo.js';
import { commands, decodeMessage, initialState, applyMessage, isValidPin, isValidToken } from './protocol.js';
import { els, render, renderTimer, showToast } from './ui.js';

const STORAGE = Object.freeze({ pin: 'ts.pin', token: 'ts.token', prefs: 'ts.prefs' });
const FONT = Object.freeze({ min: 18, max: 64, step: 4, initial: 30 });
const SILENCE_MS = 15000; // il Mac manda almeno un aggiornamento ogni 10 s
const MAX_PENDING_NAV = 2;

let model = Object.freeze({
  view: 'connect',
  conn: 'idle',
  protocol: initialState(),
  paired: false,
  demo: false,
  pin: readStorage(STORAGE.pin) ?? '',
  prefs: loadPrefs(),
  message: '',
  messageIsError: false,
  supported: isBluetoothSupported(),
  macSilent: false,
  lockedUntil: 0,
});
let transport = null;
let wakeLock = null;
let authMethod = null; // 'resume' | 'hello'
let lastMessageAt = 0;
let pendingNav = 0;
let lockRetryTimer = null;

function update(patch) {
  model = Object.freeze({ ...model, ...patch });
  render(model);
  syncWakeLock();
}

// ---------- Messaggi dal Mac ----------

function onBytes(bytes) {
  const message = decodeMessage(bytes);
  if (!message) return;
  lastMessageAt = Date.now();
  const protocol = applyMessage(model.protocol, message);

  if (message.t === 'auth') {
    handleAuth(message, protocol);
    return;
  }
  if (message.t === 'err') showToast(message.msg);
  update({ protocol, macSilent: false });
}

function handleAuth(message, protocol) {
  if (message.ok) {
    if (!model.demo) {
      writeStorage(STORAGE.pin, model.pin);
      if (isValidToken(message.token)) writeStorage(STORAGE.token, message.token);
    }
    update({ protocol, paired: true, view: 'remote', message: '', messageIsError: false, lockedUntil: 0, macSilent: false });
    return;
  }
  if (authMethod === 'resume') {
    // Riconnessione non più valida (es. codice cambiato sul Mac): si riprova col codice.
    removeStorage(STORAGE.token);
    if (isValidPin(model.pin)) {
      sendAuth('hello');
      return;
    }
  }
  if (protocol.auth === 'locked') {
    // Bloccato per tentativi altrui: si tiene il codice e si riprova da soli.
    const lockedUntil = Date.now() + protocol.retryIn * 1000;
    update({ protocol, lockedUntil, message: `Il Mac ha bloccato i tentativi: riprovo tra ${protocol.retryIn} secondi.`, messageIsError: true });
    clearTimeout(lockRetryTimer);
    lockRetryTimer = setTimeout(() => {
      if (model.conn === 'connected') sendAuth('hello');
    }, protocol.retryIn * 1000 + 500);
    return;
  }
  // Codice sbagliato: si dimentica anche il Mac scelto, così al prossimo tentativo si può sceglierne un altro.
  if (!model.demo) removeStorage(STORAGE.pin);
  transport?.disconnect({ forget: true });
  update({
    protocol, paired: false, view: 'connect',
    message: 'Codice errato (o Mac sbagliato): controlla il menu di Telecomando Slide sul Mac.', messageIsError: true,
  });
}

function sendAuth(method) {
  const token = readStorage(STORAGE.token);
  authMethod = method === 'resume' && isValidToken(token) && !model.demo ? 'resume' : 'hello';
  sendCommand(authMethod === 'resume' ? commands.resume(token) : commands.hello(model.pin));
}

function onStatus(status, detail) {
  switch (status) {
    case 'connecting':
      update({ conn: 'connecting', message: model.paired ? '' : 'Collegamento in corso…', messageIsError: false });
      break;
    case 'connected':
      lastMessageAt = Date.now();
      update({ conn: 'connected', macSilent: false });
      sendAuth('resume');
      break;
    case 'reconnecting':
      update({ conn: 'reconnecting' });
      break;
    case 'disconnected':
      update({ conn: 'disconnected', view: model.paired ? 'remote' : 'connect' });
      break;
    case 'cancelled':
      update({ conn: 'idle', message: '' });
      break;
    case 'error':
      if (model.paired) showToast(detail);
      update({ conn: model.paired ? 'disconnected' : 'idle', message: detail, messageIsError: true });
      break;
    default:
      break;
  }
}

// ---------- Azioni ----------

function connect(pin, { demo = false } = {}) {
  if (!transport || model.demo !== demo) {
    transport?.disconnect({ forget: true });
    transport = (demo ? createDemoTransport : createBleTransport)({ onBytes, onStatus });
  }
  update({ pin, demo, protocol: initialState(), message: '', messageIsError: false });
  // Nessun await prima di connect(): la scelta del dispositivo richiede il tocco in corso.
  transport.connect();
}

function sendCommand(text) {
  if (!transport) return Promise.resolve();
  return transport.send(text).catch(() => showToast('Comando non arrivato al Mac'));
}

/** Avanti/indietro: tocchi in eccesso mentre il Mac è lento vengono scartati, non accumulati. */
function sendNav(text) {
  if (pendingNav >= MAX_PENDING_NAV) return;
  pendingNav += 1;
  if (navigator.userActivation?.isActive) navigator.vibrate?.(10);
  sendCommand(text).finally(() => { pendingNav -= 1; });
}

function disconnect() {
  transport?.disconnect({ forget: true });
  transport = null;
  clearTimeout(lockRetryTimer);
  update({ paired: false, view: 'connect', conn: 'idle', protocol: initialState(), demo: false, message: '', macSilent: false });
}

function changeFont(delta) {
  const fontSize = Math.min(FONT.max, Math.max(FONT.min, model.prefs.fontSize + delta));
  const prefs = Object.freeze({ ...model.prefs, fontSize });
  writeStorage(STORAGE.prefs, JSON.stringify(prefs));
  update({ prefs });
}

// ---------- Eventi ----------

els.connectForm.addEventListener('submit', (event) => {
  event.preventDefault();
  const pin = els.pin.value.trim();
  if (!isValidPin(pin)) {
    update({ message: 'Il codice ha 4 cifre: lo trovi nel menu dell’app sul Mac.', messageIsError: true });
    els.pin.focus();
    return;
  }
  if (pin !== readStorage(STORAGE.pin)) removeStorage(STORAGE.token);
  els.pin.blur();
  connect(pin);
});
els.demoBtn.addEventListener('click', () => connect('0000', { demo: true }));

els.nextBtn.addEventListener('click', () => sendNav(commands.next()));
els.prevBtn.addEventListener('click', () => sendNav(commands.prev()));
els.blackBtn.addEventListener('click', () => sendCommand(commands.black()));
els.startBtn.addEventListener('click', () => sendCommand(commands.start()));
els.bannerBtn.addEventListener('click', () => transport?.connect());

els.menuBtn.addEventListener('click', () => els.menu.showModal());
els.menuClose.addEventListener('click', () => els.menu.close());
els.menu.addEventListener('click', (event) => {
  if (event.target === els.menu) els.menu.close(); // tocco sullo sfondo
});
els.fontDown.addEventListener('click', () => changeFont(-FONT.step));
els.fontUp.addEventListener('click', () => changeFont(FONT.step));
els.showToggle.addEventListener('click', () => {
  sendCommand(model.protocol.show?.running ? commands.stop() : commands.start());
  els.menu.close();
});
els.reloadBtn.addEventListener('click', () => {
  sendCommand(commands.reload());
  els.menu.close();
});
els.disconnectBtn.addEventListener('click', () => {
  els.menu.close();
  disconnect();
});
els.slideList.addEventListener('click', (event) => {
  const button = event.target.closest('button[data-slide]:not(:disabled)');
  if (!button) return;
  sendCommand(commands.goTo(Number(button.dataset.slide)));
  els.menu.close();
});

// Tastiera (utile anche con un telecomando/clicker collegato al telefono)
document.addEventListener('keydown', (event) => {
  if (model.view !== 'remote' || els.menu.open || event.repeat) return;
  const nav = { ArrowRight: commands.next, PageDown: commands.next, ' ': commands.next, ArrowLeft: commands.prev, PageUp: commands.prev };
  const other = { b: commands.black, B: commands.black, '.': commands.black };
  if (nav[event.key]) {
    event.preventDefault();
    sendNav(nav[event.key]());
  } else if (other[event.key]) {
    event.preventDefault();
    sendCommand(other[event.key]());
  }
});

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') transport?.reconnectNow();
  syncWakeLock();
});

setInterval(() => {
  if (model.view !== 'remote') return;
  renderTimer(model);
  const silent = model.paired && model.conn === 'connected' && Date.now() - lastMessageAt > SILENCE_MS;
  if (silent !== model.macSilent) update({ macSilent: silent });
}, 1000);

// ---------- Schermo sempre acceso ----------

function syncWakeLock() {
  const wanted = model.view === 'remote' && document.visibilityState === 'visible';
  if (wanted && !wakeLock && 'wakeLock' in navigator) {
    wakeLock = 'pending';
    navigator.wakeLock.request('screen')
      .then((lock) => {
        wakeLock = lock;
        lock.addEventListener('release', () => { wakeLock = null; });
      })
      .catch(() => { wakeLock = null; });
  } else if (!wanted && wakeLock && wakeLock !== 'pending') {
    wakeLock.release().catch(() => undefined);
    wakeLock = null;
  }
}

// ---------- Memoria locale ----------

function loadPrefs() {
  try {
    const saved = JSON.parse(readStorage(STORAGE.prefs) ?? '{}');
    const fontSize = Number.isFinite(saved.fontSize) ? saved.fontSize : FONT.initial;
    return Object.freeze({ fontSize: Math.min(FONT.max, Math.max(FONT.min, fontSize)) });
  } catch {
    return Object.freeze({ fontSize: FONT.initial });
  }
}

function readStorage(key) {
  try { return localStorage.getItem(key); } catch { return null; }
}
function writeStorage(key, value) {
  try { localStorage.setItem(key, value); } catch { /* memoria non disponibile: si continua senza */ }
}
function removeStorage(key) {
  try { localStorage.removeItem(key); } catch { /* idem */ }
}

// ---------- Avvio ----------

els.pin.value = model.pin;
render(model);
if (new URLSearchParams(location.search).has('demo')) connect('0000', { demo: true });
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('./sw.js').catch(() => undefined);
}
