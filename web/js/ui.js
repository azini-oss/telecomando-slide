// Disegno dell'interfaccia a partire dal modello. Solo textContent: le note non diventano mai HTML.
import { currentSlide, nextVisibleSlide, slideTitle, elapsedSeconds, deckMatches } from './protocol.js';

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
  idle: $('idle'),
  idleText: $('idle-text'),
  startBtn: $('start-btn'),
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
let lastListKey = '';
let toastTimer = null;

export function render(model) {
  els.app.dataset.view = model.view;
  els.app.style.setProperty('--notes-size', `${model.prefs.fontSize}px`);
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

  els.dot.className = `dot ${online ? 'ok' : conn === 'disconnected' ? 'off' : 'warn'}`;
  renderBanner(conn);

  els.counter.textContent = running ? `${show.slide} / ${show.count}` : `– / ${show?.count || '–'}`;
  els.blackBtn.setAttribute('aria-pressed', String(Boolean(show?.black)));
  els.blackBtn.disabled = !running || !online;
  els.prevBtn.disabled = !running || !online;
  els.nextBtn.disabled = !running || !online;
  els.startBtn.disabled = !online;

  renderNotes(protocol, running);
  renderNext(protocol, running);
  renderTimer(model);

  els.fontSize.textContent = String(model.prefs.fontSize);
  els.showToggle.textContent = running ? 'Termina presentazione' : 'Avvia presentazione';
  els.showToggle.disabled = !online || !show?.count;
  els.reloadBtn.disabled = !online;
  renderSlideList(protocol);
}

function renderBanner(conn) {
  const texts = {
    connecting: 'Collegamento al Mac…',
    reconnecting: 'Connessione persa: riprovo…',
    disconnected: 'Disconnesso dal Mac',
  };
  els.banner.hidden = !texts[conn];
  els.bannerText.textContent = texts[conn] ?? '';
  els.bannerBtn.hidden = conn !== 'disconnected';
}

function renderNotes(protocol, running) {
  const show = protocol.show;
  els.idle.hidden = running;
  els.notes.hidden = !running;

  if (!running) {
    els.idleText.textContent = idleText(protocol);
    els.startBtn.hidden = !(show?.ppt && show.count > 0);
    return;
  }

  const slide = currentSlide(protocol);
  const key = `${show.key}|${show.slide}|${slide?.notes ?? ''}`;
  if (!slide) {
    els.notes.textContent = deckMatches(protocol) ? '' : 'Caricamento note…';
    els.notes.classList.add('empty');
  } else {
    els.notes.textContent = slide.notes || 'Nessuna nota per questa slide.';
    els.notes.classList.toggle('empty', !slide.notes);
  }
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
  const next = running ? nextVisibleSlide(protocol) : null;
  const text = !running ? '—' : next ? `${next.index}. ${slideTitle(next, next.index)}` : 'Fine presentazione';
  if (els.nextTitle.textContent === text) return;
  els.nextTitle.textContent = text;
  updateMarquee();
}

window.addEventListener('resize', () => updateMarquee());

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
  const key = `${protocol.deck?.key}|${current}|${slides.length}`;
  if (key === lastListKey) return;
  lastListKey = key;

  const items = slides.map((slide, i) => {
    const index = i + 1;
    const li = document.createElement('li');
    const button = document.createElement('button');
    button.type = 'button';
    button.dataset.slide = String(index);
    if (index === current) button.setAttribute('aria-current', 'true');
    const num = Object.assign(document.createElement('span'), { className: 'num', textContent: String(index) });
    const title = Object.assign(document.createElement('span'), { className: 'title', textContent: slideTitle(slide, index) });
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
