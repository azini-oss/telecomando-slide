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
const slideId = (index) => 256 + index;
const DECK = Object.freeze({
  t: 'deck', key: KEY, name: 'Presentazione demo',
  slides: SLIDES.map(({ builds, ...s }, i) => ({ ...s, id: slideId(i + 1) })),
});

const DEMO_COLORS = ['#3a3a8c', '#1f6f5c', '#8c3a5a', '#555', '#7a5a1f', '#2f4f7f'];

/** Miniatura finta (JPEG in base64) disegnata con un canvas: colore e titolo della slide. */
function demoThumb(slide, index) {
  const canvas = Object.assign(document.createElement('canvas'), { width: 320, height: 180 });
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = DEMO_COLORS[index % DEMO_COLORS.length];
  ctx.fillRect(0, 0, 320, 180);
  ctx.fillStyle = '#fff';
  ctx.font = '600 22px system-ui, sans-serif';
  ctx.fillText(`${index + 1}. ${(slide.title || 'Slide').slice(0, 22)}`, 16, 96);
  return canvas.toDataURL('image/jpeg', 0.7).split(',')[1];
}

export function createDemoTransport({ onBytes, onStatus }) {
  const encoder = new TextEncoder();
  // from = slide di partenza (0 = dall'inizio): come in PowerPoint, prima di questa non si torna.
  let show = Object.freeze({ running: false, slide: 0, build: 0, black: false, startedAt: 0, from: 0 });
  let connected = false;

  const emit = (message) => setTimeout(() => onBytes(encoder.encode(JSON.stringify(message))), 40);
  const emitState = () => emit({
    t: 'state', ppt: true, running: show.running, slide: show.slide, count: SLIDES.length, black: show.black,
    elapsed: show.running ? (Date.now() - show.startedAt) / 1000 : 0, key: KEY,
    slideId: show.slide > 0 ? slideId(show.slide) : 0,
    from: show.running ? show.from : 0,
  });
  const startAt = (slide) => Object.freeze({
    ...show, running: true, slide, build: 0, black: false, startedAt: Date.now(), from: slide > 1 ? slide : 0,
  });

  const visibleFrom = (index, step) => {
    let i = index + step;
    while (i >= 1 && i <= SLIDES.length && SLIDES[i - 1].hidden) i += step;
    return i;
  };

  // slide 0 = schermata finale, come PowerPoint dopo l'ultima slide.
  const moves = {
    next: () => {
      if (show.slide === 0) return show;
      if (show.build < SLIDES[show.slide - 1].builds) return { ...show, build: show.build + 1 };
      const target = visibleFrom(show.slide, 1);
      return target > SLIDES.length ? { ...show, slide: 0, build: 0 } : { ...show, slide: target, build: 0 };
    },
    prev: () => {
      if (show.build > 0) return { ...show, build: show.build - 1 };
      if (show.from > 1 && show.slide === show.from) return show;
      const target = visibleFrom(show.slide === 0 ? SLIDES.length + 1 : show.slide, -1);
      return target < 1 ? show : { ...show, slide: target, build: SLIDES[target - 1].builds };
    },
    first: () => ({ ...show, slide: 1, build: 0 }),
    black: () => ({ ...show, black: !show.black }),
    stop: () => ({ ...show, running: false, slide: 0, build: 0, black: false }),
  };

  // Come il Mac: "export", poi una miniatura per slide visibile, poi "done".
  function sendThumbs() {
    const visible = DECK.slides.map((s, i) => ({ s, i })).filter(({ s }) => !s.hidden);
    emit({ t: 'thumbs', key: KEY, status: 'export', total: 0 });
    setTimeout(() => {
      emit({ t: 'thumbs', key: KEY, status: 'sending', total: visible.length });
      visible.forEach(({ s, i }, n) => {
        setTimeout(() => emit({ t: 'thumb', key: KEY, id: s.id, jpg: demoThumb(s, i) }), 150 * (n + 1));
      });
      setTimeout(() => emit({ t: 'thumbs', key: KEY, status: 'done', total: visible.length }), 150 * (visible.length + 1));
    }, 700);
  }

  function handle(text) {
    if (text.startsWith('hello:')) {
      emit({ t: 'auth', ok: true });
      emit(DECK);
      emitState();
      return;
    }
    const target = Number(text.split(':')[1]);
    const hiddenTarget = SLIDES[target - 1]?.hidden;
    if (text === 'start') {
      show = startAt(1);
    } else if (text.startsWith('start:') && !show.running) {
      if (hiddenTarget) emit({ t: 'err', msg: 'La slide è nascosta: in presentazione non ci si può andare' });
      else if (target >= 1 && target <= SLIDES.length) show = startAt(target);
    } else if (text === 'reload') {
      emit(DECK);
    } else if (text === 'thumbs') {
      sendThumbs();
      return;
    } else if ((text.startsWith('goto:') || text.startsWith('start:')) && show.running) {
      if (hiddenTarget) emit({ t: 'err', msg: 'La slide è nascosta: in presentazione non ci si può andare' });
      else if (show.from > 1 && target < show.from) show = startAt(target); // riavvio, come sul Mac
      else if (target >= 1 && target <= SLIDES.length) show = Object.freeze({ ...show, slide: target, build: 0 });
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
