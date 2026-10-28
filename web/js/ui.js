// Disegno dell'interfaccia a partire dal modello. Solo textContent: le note non diventano mai HTML.
import {
  currentSlide, nextVisibleSlide, slideTitle, elapsedSeconds, deckMatches, notesStatus, isShowEnded,
  thumbFor, thumbProgress,
} from './protocol.js';

const $ = (id) => document.getElementById(id);

export const els = Object.freeze({
  app: $('app'),
  connectForm: $('connect-form'),
  pin: $('pin'),
  connectBtn: $('connect-btn'),
  connectMessage: $('connect-message'),
  unsupported: $('unsupported'),
  demoBtn: $('demo-btn'),
  dot: $('conn-dot'),
  counter: $('counter'),
  timer: $('timer'),
  blackBtn: $('black-btn'),
  menuBtn: $('menu-btn'),
  banner: $('banner'),
  bannerText: $('banner-text'),
  bannerBtn: $('banner-btn'),
  notes: $('notes'),
  notesText: $('notes-text'),
  currentThumb: $('current-thumb'),
  nextThumb: $('next-thumb'),
  thumbsBtn: $('thumbs-btn'),
  thumbsToggle: $('thumbs-toggle'),
  thumbsIdleBtn: $('thumbs-idle-btn'),
  idle: $('idle'),
  idleText: $('idle-text'),
  startBtn: $('start-btn'),
  startFromBtn: $('start-from-btn'),
  slideListTitle: $('slide-list-title'),
  nextWrap: $('next-title-wrap'),
  nextTitle: $('next-title'),
  prevBtn: $('prev-btn'),
  nextBtn: $('next-btn'),
  menu: $('menu'),
  fontDown: $('font-down'),
  fontUp: $('font-up'),
  fontSize: $('font-size'),
  showToggle: $('show-toggle'),
  reloadBtn: $('reload-btn'),
  disconnectBtn: $('disconnect-btn'),
  slideList: $('slide-list'),
  menuClose: $('menu-close'),
  toast: $('toast'),
});

let lastNotesKey = '';
let lastListDeck = null;
let lastListCurrent = -1;
let lastListThumbs = null;
let toastTimer = null;

export function render(model) {
  els.app.dataset.view = model.view;
  els.app.style.setProperty('--notes-size', `${model.prefs.fontSize}px`);
  els.app.classList.toggle('no-thumbs', !model.prefs.showThumbs);
  renderConnect(model);
  if (model.view === 'remote') renderRemote(model);
}

function renderConnect(model) {
  const busy = model.conn === 'connecting' && !model.paired;
  els.connectBtn.disabled = busy || !model.supported;
  els.connectBtn.textContent = busy ? 'Collegamento…' : 'Connetti al Mac';
  els.unsupported.hidden = model.supported;
  els.connectMessage.textContent = model.message;
  els.connectMessage.classList.toggle('error', model.messageIsError);
}

function renderRemote(model) {
  const { protocol, conn } = model;
  const show = protocol.show;
  const running = Boolean(show?.running);
  const online = conn === 'connected';

  const healthy = online && !model.macSilent;
  els.dot.className = `dot ${healthy ? 'ok' : conn === 'disconnected' ? 'off' : 'warn'}`;
  renderBanner(model);

  const ended = isShowEnded(protocol);
  els.counter.textContent = ended ? `Fine / ${show.count}` : running ? `${show.slide} / ${show.count}` : `– / ${show?.count || '–'}`;
  els.blackBtn.setAttribute('aria-pressed', String(Boolean(show?.black)));
  els.blackBtn.disabled = !running || !online;
  els.prevBtn.disabled = !running || !online;
  els.nextBtn.disabled = !running || !online;
  els.startBtn.disabled = !online;
  els.startFromBtn.disabled = !online || !deckMatches(protocol);

  renderNotes(protocol, running);
  renderNext(protocol, running);
  renderTimer(model);
  renderThumbControls(model, online);

  els.fontSize.textContent = String(model.prefs.fontSize);
  els.showToggle.textContent = running ? 'Termina presentazione' : 'Avvia dall’inizio';
  els.slideListTitle.textContent = running ? 'Vai alla slide' : 'Avvia dalla slide';
  els.showToggle.disabled = !online || !show?.count;
  els.reloadBtn.disabled = !online;
  renderSlideList(protocol);
}

function renderBanner(model) {
  const texts = {
    connecting: 'Collegamento al Mac…',
    reconnecting: 'Connessione persa: riprovo…',
    disconnected: 'Disconnesso dal Mac',
  };
  const lockedFor = Math.ceil((model.lockedUntil - Date.now()) / 1000);
  const text = texts[model.conn]
    ?? (model.macSilent ? 'Il Mac non risponde: controlla PowerPoint sul Mac' : null)
    ?? (lockedFor > 0 ? `Il Mac ha bloccato i tentativi: riprovo tra ${lockedFor} s` : null);
  els.banner.hidden = !text;
  els.bannerText.textContent = text ?? '';
  els.bannerBtn.hidden = model.conn !== 'disconnected';
}

const NOTES_PLACEHOLDER = Object.freeze({
  ended: 'Fine della presentazione.\nTocca Indietro per tornare all’ultima slide.',
  loading: 'Caricamento note…',
  stale: 'Aggiornamento note…',
});

function renderNotes(protocol, running) {
  const show = protocol.show;
  els.idle.hidden = running;
  els.notes.hidden = !running;

  if (!running) {
    els.idleText.textContent = idleText(protocol);
    const canStart = Boolean(show?.ppt && show.count > 0);
    els.startBtn.hidden = !canStart;
    els.startFromBtn.hidden = !canStart || show.count < 2;
    return;
  }

  const status = notesStatus(protocol);
  const slide = currentSlide(protocol);
  const key = `${show.key}|${show.slide}|${status}|${slide?.notes ?? ''}`;
  if (slide) {
    els.notesText.textContent = slide.notes || 'Nessuna nota per questa slide.';
    els.notes.classList.toggle('empty', !slide.notes);
  } else {
    els.notesText.textContent = NOTES_PLACEHOLDER[status] ?? '';
    els.notes.classList.add('empty');
  }
  setThumb(els.currentThumb, slide ? thumbFor(protocol, slide.id) : null);
  if (key !== lastNotesKey) {
    els.notes.scrollTop = 0;
    lastNotesKey = key;
  }
}

function idleText(protocol) {
  const show = protocol.show;
  if (!show) return 'In attesa del Mac…';
  if (!show.ppt) return 'Apri PowerPoint sul Mac.';
  if (!show.count) return 'Apri una presentazione in PowerPoint.';
  const name = deckMatches(protocol) ? `«${protocol.deck.name}»` : 'La presentazione';
  return `${name} è pronta · ${show.count} slide`;
}

function renderNext(protocol, running) {
  const status = notesStatus(protocol);
  const next = running ? nextVisibleSlide(protocol) : null;
  const text = !running || status === 'ended' || status === 'stale' || status === 'loading'
    ? '—'
    : next ? `${next.index}. ${slideTitle(next, next.index)}` : 'Fine presentazione';
  setThumb(els.nextThumb, text !== '—' && next ? thumbFor(protocol, next.id) : null);
  if (els.nextTitle.textContent === text) return;
  els.nextTitle.textContent = text;
  updateMarquee();
}

window.addEventListener('resize', () => updateMarquee());

/** Mostra la miniatura se c'è (data URL già validato dal protocollo), altrimenti la nasconde. */
function setThumb(img, src) {
  if (!src) {
    img.hidden = true;
    img.removeAttribute('src');
    return;
  }
  if (img.getAttribute('src') !== src) img.src = src;
  img.hidden = false;
}

function renderThumbControls(model, online) {
  const progress = thumbProgress(model.protocol);
  const busy = progress?.status === 'export' || progress?.status === 'sending';
  const loaded = Object.keys(model.protocol.thumbs.images).length > 0 && model.protocol.thumbs.key === model.protocol.deck?.key;
  const label = !progress ? 'Carica miniature'
    : progress.status === 'export' ? 'Miniature: PowerPoint le sta esportando…'
      : progress.status === 'sending' ? `Miniature: ${progress.received} di ${progress.total}…`
        : progress.status === 'error' ? 'Riprova a caricare le miniature'
          : 'Aggiorna miniature';
  els.thumbsBtn.textContent = label;
  els.thumbsBtn.disabled = !online || busy || !deckMatches(model.protocol);
  els.thumbsIdleBtn.textContent = !progress || progress.status === 'error' ? 'Carica le miniature' : label;
  els.thumbsIdleBtn.disabled = els.thumbsBtn.disabled;
  els.thumbsIdleBtn.hidden = !model.protocol.show?.count || (loaded && !busy);
  els.thumbsToggle.hidden = !loaded;
  els.thumbsToggle.textContent = model.prefs.showThumbs ? 'Nascondi miniature' : 'Mostra miniature';
}

/** Titolo lungo: scorre avanti e indietro invece di essere troncato. */
function updateMarquee() {
  const distance = els.nextTitle.scrollWidth - els.nextWrap.clientWidth;
  const scrolling = distance > 4;
  els.nextWrap.classList.toggle('marquee', scrolling);
  els.nextWrap.style.setProperty('--marquee-distance', `${Math.max(0, distance)}px`);
  els.nextWrap.style.setProperty('--marquee-time', `${Math.min(16, 4 + distance / 40).toFixed(1)}s`);
}

export function renderTimer(model) {
  els.timer.textContent = formatTime(elapsedSeconds(model.protocol));
}

export function formatTime(totalSeconds) {
  const s = Math.max(0, Math.floor(totalSeconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = String(s % 60).padStart(2, '0');
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`;
}

function renderSlideList(protocol) {
  const slides = protocol.deck?.slides ?? [];
  const current = protocol.show?.running ? protocol.show.slide : 0;
  // Si ridisegna quando arriva un deck nuovo (anche con la stessa chiave) o cambia la slide.
  if (protocol.deck === lastListDeck && current === lastListCurrent && protocol.thumbs === lastListThumbs) return;
  lastListDeck = protocol.deck;
  lastListCurrent = current;
  lastListThumbs = protocol.thumbs;

  const items = slides.map((slide, i) => {
    const index = i + 1;
    const li = document.createElement('li');
    const button = document.createElement('button');
    button.type = 'button';
    button.dataset.slide = String(index);
    // In presentazione PowerPoint non può mostrare le slide nascoste: non sono toccabili.
    button.disabled = Boolean(slide.hidden);
    if (index === current) button.setAttribute('aria-current', 'true');
    const num = Object.assign(document.createElement('span'), { className: 'num', textContent: String(index) });
    const title = Object.assign(document.createElement('span'), { className: 'title', textContent: slideTitle(slide, index) });
    const src = thumbFor(protocol, slide.id);
    if (src) button.append(Object.assign(document.createElement('img'), { className: 'thumb', src, alt: '' }));
    button.append(num, title);
    if (slide.hidden) button.append(Object.assign(document.createElement('span'), { className: 'tag', textContent: 'nascosta' }));
    li.append(button);
    return li;
  });
  els.slideList.replaceChildren(...items);
}

export function showToast(text, ms = 3500) {
  clearTimeout(toastTimer);
  els.toast.textContent = text;
  els.toast.hidden = false;
  toastTimer = setTimeout(() => { els.toast.hidden = true; }, ms);
}
