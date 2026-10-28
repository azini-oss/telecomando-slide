// Frame Bluetooth: [id messaggio u8][indice u16 BE][totale u16 BE][dati].
// Stesso formato dell'app Mac (mac/Sources/Framing.swift), verificato con shared/framing-vectors.json.

export const HEADER_SIZE = 5;
// Stesso limite del Mac (BLEPeripheral.maxFramesPerMessage): tiene limitato il lavoro di riassemblaggio.
export const MAX_FRAMES = 4096;
const MAX_PENDING = 4;

export function encodeFrames(bytes, messageId, maxFrameSize) {
  const chunk = Math.max(1, maxFrameSize - HEADER_SIZE);
  const total = Math.max(1, Math.ceil(bytes.length / chunk));
  return Array.from({ length: total }, (_, index) => {
    const part = bytes.subarray(index * chunk, (index + 1) * chunk);
    const frame = new Uint8Array(HEADER_SIZE + part.length);
    frame.set([messageId & 0xff, index >> 8, index & 0xff, total >> 8, total & 0xff]);
    frame.set(part, HEADER_SIZE);
    return frame;
  });
}

export function parseFrame(frame) {
  if (!(frame instanceof Uint8Array) || frame.length < HEADER_SIZE) return null;
  const index = (frame[1] << 8) | frame[2];
  const total = (frame[3] << 8) | frame[4];
  if (total === 0 || total > MAX_FRAMES || index >= total) return null;
  return { messageId: frame[0], index, total, payload: frame.slice(HEADER_SIZE) };
}

export function emptyBuffers() {
  return new Map();
}

/**
 * Aggiunge un frame ai buffer in arrivo. Non modifica `buffers`: restituisce
 * i nuovi buffer e, se il messaggio è completo, i suoi byte.
 */
export function addFrame(buffers, rawFrame) {
  const frame = parseFrame(rawFrame);
  if (!frame) return { buffers, message: null };

  const existing = buffers.get(frame.messageId);
  const base = existing && existing.total === frame.total
    ? existing
    : { total: frame.total, parts: new Array(frame.total).fill(null), received: 0 };

  if (base.parts[frame.index] !== null) return { buffers, message: null };

  const parts = base.parts.map((p, i) => (i === frame.index ? frame.payload : p));
  const entry = { total: base.total, parts, received: base.received + 1 };

  if (entry.received === entry.total) {
    const next = new Map(buffers);
    next.delete(frame.messageId);
    return { buffers: next, message: concat(parts) };
  }

  const next = new Map(buffers);
  next.delete(frame.messageId); // reinserito in coda: l'ordine della Map = età
  next.set(frame.messageId, entry);
  return { buffers: trimOldest(next), message: null };
}

function trimOldest(buffers) {
  if (buffers.size <= MAX_PENDING) return buffers;
  const keep = [...buffers.entries()].slice(buffers.size - MAX_PENDING);
  return new Map(keep);
}

function concat(parts) {
  const length = parts.reduce((sum, p) => sum + p.length, 0);
  const out = new Uint8Array(length);
  parts.reduce((offset, p) => {
    out.set(p, offset);
    return offset + p.length;
  }, 0);
  return out;
}
