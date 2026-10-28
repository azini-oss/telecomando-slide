// Protocollo tra telefono e app Mac. Funzioni pure: nessun accesso a DOM o Bluetooth.

export const SERVICE_UUID = 'e42b5411-b077-4060-b77f-1fdc51501853';
export const COMMAND_UUID = '3589d7a0-018d-4575-bcd8-3ad5e6fa1996';
export const EVENT_UUID = 'b3646ad2-5c8f-40f3-8905-5a5a9842889d';

const MAX_SLIDE = 9999;

export function isValidPin(pin) {
  return typeof pin === 'string' && /^[0-9]{4}$/.test(pin);
}

export function isValidToken(token) {
  return typeof token === 'string' && /^[0-9a-f]{32}$/.test(token);
}

export const commands = Object.freeze({
  hello: (pin) => {
    if (!isValidPin(pin)) throw new Error('Il codice deve avere 4 cifre');
    return `hello:${pin}`;
  },
  resume: (token) => {
    if (!isValidToken(token)) throw new Error('Token di riconnessione non valido');
    return `resume:${token}`;
  },
  next: () => 'next',
  prev: () => 'prev',
  first: () => 'first',
  goTo: (slide) => {
    if (!Number.isInteger(slide) || slide < 1 || slide > MAX_SLIDE) throw new Error(`Slide non valida: ${slide}`);
    return `goto:${slide}`;
  },
  start: () => 'start',
  startFrom: (slide) => {
    if (!Number.isInteger(slide) || slide < 1 || slide > MAX_SLIDE) throw new Error(`Slide non valida: ${slide}`);
    return slide === 1 ? 'start' : `start:${slide}`;
  },
  stop: () => 'stop',
  black: () => 'black',
  reload: () => 'reload',
  thumbs: () => 'thumbs',
});

const KNOWN_TYPES = new Set(['state', 'deck', 'auth', 'err', 'thumb', 'thumbs']);
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const MAX_THUMB_CHARS = 60_000; // il Mac le tiene sotto i 30 KB (≈ 40 000 caratteri in base64)

export function decodeMessage(bytes) {
  try {
    const message = JSON.parse(new TextDecoder().decode(bytes));
    return message && KNOWN_TYPES.has(message.t) ? message : null;
  } catch {
    return null;
  }
}

export function initialState() {
  return Object.freeze({
    auth: 'none', // none | ok | rejected | locked
    retryIn: 0,
    token: null,
    deck: null,
    show: null,
    showReceivedAt: 0,
    error: null,
    thumbs: Object.freeze({ key: null, images: Object.freeze({}) }),
    thumbsStatus: null,
  });
}

function addThumb(state, message) {
  const valid = Number.isInteger(message.id) && typeof message.jpg === 'string'
    && message.jpg.length <= MAX_THUMB_CHARS && BASE64.test(message.jpg);
  if (!valid) return state;
  const images = message.key === state.thumbs.key ? state.thumbs.images : {};
  return Object.freeze({
    ...state,
    thumbs: Object.freeze({
      key: message.key,
      images: Object.freeze({ ...images, [message.id]: `data:image/jpeg;base64,${message.jpg}` }),
    }),
  });
}

export function applyMessage(state, message, now = Date.now()) {
  switch (message.t) {
    case 'auth':
      if (message.ok) return Object.freeze({ ...state, auth: 'ok', retryIn: 0, token: message.token ?? null });
      return Object.freeze({
        ...state,
        auth: message.retryIn ? 'locked' : 'rejected',
        retryIn: message.retryIn ?? 0,
      });
    case 'deck':
      return Object.freeze({
        ...state,
        deck: Object.freeze({ key: message.key, name: message.name, slides: Object.freeze([...message.slides]) }),
      });
    case 'state': {
      const { t, ...show } = message;
      return Object.freeze({ ...state, show: Object.freeze(show), showReceivedAt: now });
    }
    case 'err':
      return Object.freeze({ ...state, error: Object.freeze({ msg: message.msg, at: now }) });
    case 'thumb':
      return addThumb(state, message);
    case 'thumbs':
      return Object.freeze({
        ...state,
        thumbsStatus: Object.freeze({ key: message.key, status: message.status, total: message.total ?? 0 }),
      });
    default:
      return state;
  }
}

/** True quando note e stato si riferiscono alla stessa presentazione. */
export function deckMatches(state) {
  return Boolean(state.deck && state.show && state.deck.key === state.show.key);
}

/** Le note in memoria sono di un'altra disposizione delle slide (riordinate durante le prove). */
function slideIdMismatch(slide, show) {
  return Boolean(slide?.id && show.slideId && slide.id !== show.slideId);
}

export function isShowEnded(state) {
  return Boolean(state.show?.running && state.show.slide === 0);
}

/** 'idle' (non avviata) | 'ended' (schermata finale) | 'loading' | 'stale' | 'ok' */
export function notesStatus(state) {
  if (!state.show?.running) return 'idle';
  if (isShowEnded(state)) return 'ended';
  if (!deckMatches(state)) return 'loading';
  const slide = state.deck.slides[state.show.slide - 1];
  if (!slide || slideIdMismatch(slide, state.show)) return 'stale';
  return 'ok';
}

export function currentSlide(state) {
  if (notesStatus(state) !== 'ok') return null;
  const index = state.show.slide;
  return { ...state.deck.slides[index - 1], index };
}

export function nextVisibleSlide(state) {
  if (!deckMatches(state) || isShowEnded(state)) return null;
  if (state.show.running && slideIdMismatch(state.deck.slides[state.show.slide - 1], state.show)) return null;
  const slides = state.deck.slides;
  const start = state.show.running ? state.show.slide : 0;
  const offset = slides.slice(start).findIndex((s) => !s.hidden);
  return offset === -1 ? null : { ...slides[start + offset], index: start + offset + 1 };
}

/** Miniatura di una slide (data URL) se appartiene alla presentazione mostrata. */
export function thumbFor(state, slideId) {
  if (!slideId || !state.deck || state.thumbs.key !== state.deck.key) return null;
  return state.thumbs.images[slideId] ?? null;
}

/** null se non richieste; altrimenti { status, received, total }. */
export function thumbProgress(state) {
  if (!state.thumbsStatus) return null;
  const received = state.thumbs.key === state.thumbsStatus.key ? Object.keys(state.thumbs.images).length : 0;
  return { status: state.thumbsStatus.status, received, total: state.thumbsStatus.total };
}

export function slideTitle(slide, index) {
  const title = (slide?.title ?? '').replace(/\s+/g, ' ').trim();
  return title || `Slide ${index}`;
}

export function elapsedSeconds(state, now = Date.now()) {
  if (!state.show?.running) return 0;
  return state.show.elapsed + Math.max(0, now - state.showReceivedAt) / 1000;
}
