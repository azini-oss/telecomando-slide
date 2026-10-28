// Protocollo tra telefono e app Mac. Funzioni pure: nessun accesso a DOM o Bluetooth.

export const SERVICE_UUID = 'e42b5411-b077-4060-b77f-1fdc51501853';
export const COMMAND_UUID = '3589d7a0-018d-4575-bcd8-3ad5e6fa1996';
export const EVENT_UUID = 'b3646ad2-5c8f-40f3-8905-5a5a9842889d';

const MAX_SLIDE = 9999;

export function isValidPin(pin) {
  return typeof pin === 'string' && /^[0-9]{4}$/.test(pin);
}

export const commands = Object.freeze({
  hello: (pin) => {
    if (!isValidPin(pin)) throw new Error('Il codice deve avere 4 cifre');
    return `hello:${pin}`;
  },
  next: () => 'next',
  prev: () => 'prev',
  first: () => 'first',
  goTo: (slide) => {
    if (!Number.isInteger(slide) || slide < 1 || slide > MAX_SLIDE) throw new Error(`Slide non valida: ${slide}`);
    return `goto:${slide}`;
  },
  start: () => 'start',
  stop: () => 'stop',
  black: () => 'black',
  reload: () => 'reload',
});

const KNOWN_TYPES = new Set(['state', 'deck', 'auth', 'err']);

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
    deck: null,
    show: null,
    showReceivedAt: 0,
    error: null,
  });
}

export function applyMessage(state, message, now = Date.now()) {
  switch (message.t) {
    case 'auth':
      if (message.ok) return Object.freeze({ ...state, auth: 'ok', retryIn: 0 });
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
    default:
      return state;
  }
}

/** True quando note e stato si riferiscono alla stessa presentazione. */
export function deckMatches(state) {
  return Boolean(state.deck && state.show && state.deck.key === state.show.key);
}

export function currentSlide(state) {
  if (!deckMatches(state) || !state.show.running) return null;
  const index = state.show.slide;
  const slide = state.deck.slides[index - 1];
  return slide ? { ...slide, index } : null;
}

export function nextVisibleSlide(state) {
  if (!deckMatches(state)) return null;
  const slides = state.deck.slides;
  const start = state.show.running ? state.show.slide : 0;
  const offset = slides.slice(start).findIndex((s) => !s.hidden);
  return offset === -1 ? null : { ...slides[start + offset], index: start + offset + 1 };
}

export function slideTitle(slide, index) {
  const title = (slide?.title ?? '').replace(/\s+/g, ' ').trim();
  return title || `Slide ${index}`;
}

export function elapsedSeconds(state, now = Date.now()) {
  if (!state.show?.running) return 0;
  return state.show.elapsed + Math.max(0, now - state.showReceivedAt) / 1000;
}
