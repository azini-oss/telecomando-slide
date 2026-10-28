// Collega interfaccia, protocollo e Bluetooth (o la demo).
import { createBleTransport, isBluetoothSupported } from './ble.js';
import { createDemoTransport } from './demo.js';
import { commands, decodeMessage, initialState, applyMessage, isValidPin } from './protocol.js';
import { els, render, renderTimer, showToast } from './ui.js';

const STORAGE = Object.freeze({ pin: 'ts.pin', prefs: 'ts.prefs' });
const FONT = Object.freeze({ min: 18, max: 64, step: 4, initial: 30 });

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
});
let transport = null;
let wakeLock = null;

function update(patch) {
  model = Object.freeze({ ...model, ...patch });
  render(model);
  syncWakeLock();
}

// ---------- Messaggi dal Mac ----------

function onBytes(bytes) {
  const message = decodeMessage(bytes);
  if (!message) return;
  const protocol = applyMessage(model.protocol, message);

  if (message.t === 'auth' && message.ok) {
    if (!model.demo) writeStorage(STORAGE.pin, model.pin);
    update({ protocol, paired: true, view: 'remote', message: '', messageIsError: false });
    return;
  }
  if (message.t === 'auth') {
    transport?.disconnect();
    if (!model.demo) removeStorage(STORAGE.pin);
    const text = protocol.auth === 'locked'
      ? `Troppi tentativi: riprova tra ${protocol.retryIn} secondi.`
      : 'Codice errato: controlla il menu di Telecomando Slide sul Mac.';
    update({ protocol, paired: false, view: 'connect', message: text, messageIsError: true });
    return;
  }
  if (message.t === 'err') showToast(message.msg);
  update({ protocol });
}

function onStatus(status, detail) {
  switch (status) {
    case 'connecting':
      update({ conn: 'connecting', message: model.paired ? '' : 'Collegamento in corso…', messageIsError: false });
      break;
    case 'connected':
      update({ conn: 'connected' });
      sendCommand(commands.hello(model.pin));
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
  if (!transport) return;
  transport.send(text).catch(() => showToast('Comando non arrivato al Mac'));
}

function disconnect() {
  transport?.disconnect({ forget: true });
  transport = null;
  update({ paired: false, view: 'connect', conn: 'idle', protocol: initialState(), demo: false, message: '' });
}

function changeFont(delta) {
  const fontSize = Math.min(FONT.max, Math.max(FONT.min, model.prefs.fontSize + delta));
  const prefs = Object.freeze({ ...model.prefs, fontSize });
  writeStorage(STORAGE.prefs, JSON.stringify(prefs));
  update({ prefs });
}

function haptic() {
  navigator.vibrate?.(10);
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
  els.pin.blur();
  connect(pin);
});
els.demoBtn.addEventListener('click', () => connect('0000', { demo: true }));

els.nextBtn.addEventListener('click', () => sendCommand(commands.next()));
els.prevBtn.addEventListener('click', () => sendCommand(commands.prev()));
els.nextBtn.addEventListener('pointerdown', haptic);
els.prevBtn.addEventListener('pointerdown', haptic);
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
  const button = event.target.closest('button[data-slide]');
  if (!button) return;
  sendCommand(commands.goTo(Number(button.dataset.slide)));
  els.menu.close();
});

// Tastiera (utile anche con un telecomando/clicker collegato al telefono)
document.addEventListener('keydown', (event) => {
  if (model.view !== 'remote' || els.menu.open || event.repeat) return;
  const actions = {
    ArrowRight: commands.next, PageDown: commands.next, ' ': commands.next,
    ArrowLeft: commands.prev, PageUp: commands.prev,
    b: commands.black, B: commands.black, '.': commands.black,
  };
  const action = actions[event.key];
  if (!action) return;
  event.preventDefault();
  sendCommand(action());
});

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') transport?.reconnectNow();
  syncWakeLock();
});

setInterval(() => {
  if (model.view === 'remote') renderTimer(model);
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
