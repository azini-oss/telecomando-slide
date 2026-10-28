// Collegamento Web Bluetooth con l'app Mac (Chrome su Android, Bluefy su iPhone).
import { SERVICE_UUID, COMMAND_UUID, EVENT_UUID } from './protocol.js';
import { addFrame, emptyBuffers } from './framing.js';

const RETRY_DELAYS_MS = [1000, 2000, 3000, 5000, 8000, 10000, 10000, 10000];
const WRITE_TIMEOUT_MS = 5000;
// Il Mac si annuncia come "Telecomando Slide XXXX" (codice breve per distinguere più Mac).
const NAME_PREFIX = 'Telecomando Slide';

export function isBluetoothSupported() {
  return typeof navigator !== 'undefined' && Boolean(navigator.bluetooth);
}

/**
 * onBytes(Uint8Array): messaggio completo ricevuto dal Mac.
 * onStatus(status, detail): 'connecting' | 'connected' | 'reconnecting' | 'disconnected' | 'cancelled' | 'error'.
 */
export function createBleTransport({ onBytes, onStatus }) {
  const encoder = new TextEncoder();
  let device = null;
  let commandChar = null;
  let eventChar = null;
  let buffers = emptyBuffers();
  let writeChain = Promise.resolve();
  let retryIndex = 0;
  let retryTimer = null;
  let closedByUser = false;
  let attaching = null;

  const handleValue = (event) => {
    const view = event.target.value;
    const frame = new Uint8Array(view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength));
    const result = addFrame(buffers, frame);
    buffers = result.buffers;
    if (result.message) onBytes(result.message);
  };

  /** Un solo collegamento alla volta: chiamate ripetute aspettano quello in corso. */
  function attach() {
    if (!attaching) {
      attaching = doAttach().finally(() => { attaching = null; });
    }
    return attaching;
  }

  async function doAttach() {
    if (device.gatt.connected && commandChar) return;
    onStatus('connecting');
    const server = await device.gatt.connect();
    const service = await server.getPrimaryService(SERVICE_UUID);
    commandChar = await service.getCharacteristic(COMMAND_UUID);
    eventChar?.removeEventListener('characteristicvaluechanged', handleValue);
    eventChar = await service.getCharacteristic(EVENT_UUID);
    buffers = emptyBuffers();
    eventChar.addEventListener('characteristicvaluechanged', handleValue);
    await eventChar.startNotifications();
    retryIndex = 0;
    onStatus('connected');
  }

  function scheduleRetry() {
    clearTimeout(retryTimer);
    if (closedByUser || !device) return;
    if (retryIndex >= RETRY_DELAYS_MS.length) {
      onStatus('disconnected');
      return;
    }
    onStatus('reconnecting');
    retryTimer = setTimeout(async () => {
      retryIndex += 1;
      try {
        await attach();
      } catch {
        scheduleRetry();
      }
    }, RETRY_DELAYS_MS[retryIndex]);
  }

  function onDisconnected() {
    commandChar = null;
    if (closedByUser) {
      onStatus('disconnected');
      return;
    }
    scheduleRetry();
  }

  /** Va chiamata da un tocco dell'utente: la prima volta apre la scelta del dispositivo. */
  async function connect() {
    closedByUser = false;
    clearTimeout(retryTimer);
    retryIndex = 0;
    try {
      if (!device) {
        device = await navigator.bluetooth.requestDevice({
          filters: [{ services: [SERVICE_UUID] }, { namePrefix: NAME_PREFIX }],
          optionalServices: [SERVICE_UUID],
        });
        device.addEventListener('gattserverdisconnected', onDisconnected);
      }
      await attach();
    } catch (error) {
      if (error?.name === 'NotFoundError') {
        onStatus('cancelled');
        return;
      }
      onStatus('error', describeError(error));
    }
  }

  /** Riprova subito (es. quando la pagina torna visibile). */
  function reconnectNow() {
    if (!device || closedByUser || device.gatt.connected || attaching) return;
    retryIndex = 0;
    scheduleRetry();
  }

  function send(text) {
    const job = writeChain.then(() => {
      if (!commandChar) throw new Error('Non collegato');
      return withTimeout(commandChar.writeValueWithResponse(encoder.encode(text)), WRITE_TIMEOUT_MS);
    });
    writeChain = job.catch(() => undefined);
    return job;
  }

  function disconnect({ forget = false } = {}) {
    closedByUser = true;
    clearTimeout(retryTimer);
    if (device?.gatt.connected) device.gatt.disconnect();
    else onStatus('disconnected');
    if (forget) {
      device?.removeEventListener('gattserverdisconnected', onDisconnected);
      device = null;
    }
  }

  return { connect, reconnectNow, send, disconnect };
}

function withTimeout(promise, ms) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('Il Mac non ha risposto in tempo')), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function describeError(error) {
  const message = String(error?.message ?? error ?? '');
  if (error?.name === 'SecurityError') return 'Il browser ha bloccato il Bluetooth: apri la pagina da HTTPS.';
  if (error?.name === 'NetworkError') return 'Mac non raggiungibile: controlla che l\'app sia aperta e il Bluetooth acceso.';
  if (/globally disabled|adapter not available/i.test(message)) return 'Accendi il Bluetooth sul telefono.';
  return message ? `Errore Bluetooth: ${message}` : 'Errore Bluetooth sconosciuto.';
}
