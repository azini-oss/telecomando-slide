// Mac simulato: per provare l'interfaccia senza Bluetooth né PowerPoint.

const SLIDES = Object.freeze([
  { title: 'Benvenuti', notes: 'Saluta e presentati.\nRingrazia per il tempo.', hidden: false, builds: 0 },
  {
    title: 'Il problema',
    notes: 'Tre punti, uno per clic:\n• strumenti sparsi\n• file ovunque\n• costi scoperti a fine mese',
    hidden: false,
    builds: 2,
  },
  {
    title: 'Una soluzione unica per tutto il processo produttivo, dal brief alla consegna',
    notes: 'Pausa di due secondi prima di parlare.\n\nQuesta è la slide più importante: rallenta, guarda le persone, e racconta un esempio concreto di un progetto recente. Se il tempo stringe, salta direttamente alla demo.',
    hidden: false,
    builds: 0,
  },
  { title: 'Costi (backup)', notes: 'Solo se chiedono dei costi.', hidden: true, builds: 0 },
  { title: '', notes: '', hidden: false, builds: 0 },
  { title: 'Domande', notes: 'Lascia questa slide accesa durante il Q&A.', hidden: false, builds: 0 },
]);

const KEY = 'demo#6';
const DECK = Object.freeze({ t: 'deck', key: KEY, name: 'Presentazione demo', slides: SLIDES.map(({ builds, ...s }) => s) });

export function createDemoTransport({ onBytes, onStatus }) {
  const encoder = new TextEncoder();
  let show = Object.freeze({ running: false, slide: 0, build: 0, black: false, startedAt: 0 });
  let connected = false;

  const emit = (message) => setTimeout(() => onBytes(encoder.encode(JSON.stringify(message))), 40);
  const emitState = () => emit({
    t: 'state', ppt: true, running: show.running, slide: show.slide, count: SLIDES.length, black: show.black,
    elapsed: show.running ? (Date.now() - show.startedAt) / 1000 : 0, key: KEY,
  });

  const visibleFrom = (index, step) => {
    let i = index + step;
    while (i >= 1 && i <= SLIDES.length && SLIDES[i - 1].hidden) i += step;
    return i;
  };

  const moves = {
    next: () => {
      if (show.build < SLIDES[show.slide - 1].builds) return { ...show, build: show.build + 1 };
      const target = visibleFrom(show.slide, 1);
      return target > SLIDES.length ? show : { ...show, slide: target, build: 0 };
    },
    prev: () => {
      if (show.build > 0) return { ...show, build: show.build - 1 };
      const target = visibleFrom(show.slide, -1);
      return target < 1 ? show : { ...show, slide: target, build: SLIDES[target - 1].builds };
    },
    first: () => ({ ...show, slide: 1, build: 0 }),
    black: () => ({ ...show, black: !show.black }),
    stop: () => ({ ...show, running: false, slide: 0, build: 0, black: false }),
  };

  function handle(text) {
    if (text.startsWith('hello:')) {
      emit({ t: 'auth', ok: true });
      emit(DECK);
      emitState();
      return;
    }
    if (text === 'start') {
      show = Object.freeze({ ...show, running: true, slide: 1, build: 0, startedAt: Date.now() });
    } else if (text === 'reload') {
      emit(DECK);
    } else if (text.startsWith('goto:') && show.running) {
      const target = Number(text.slice(5));
      if (target >= 1 && target <= SLIDES.length) show = Object.freeze({ ...show, slide: target, build: 0 });
    } else if (moves[text] && show.running) {
      show = Object.freeze(moves[text]());
    } else if (!show.running) {
      emit({ t: 'err', msg: 'La presentazione non è avviata' });
    }
    emitState();
  }

  return {
    async connect() {
      onStatus('connecting');
      await new Promise((resolve) => setTimeout(resolve, 400));
      connected = true;
      onStatus('connected');
    },
    reconnectNow() {},
    async send(text) {
      if (!connected) throw new Error('Non collegato');
      handle(text);
    },
    disconnect() {
      connected = false;
      onStatus('disconnected');
    },
  };
}
