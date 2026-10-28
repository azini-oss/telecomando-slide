import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  commands,
  isValidPin,
  isValidToken,
  decodeMessage,
  initialState,
  applyMessage,
  currentSlide,
  nextVisibleSlide,
  notesStatus,
  slideTitle,
  elapsedSeconds,
} from '../web/js/protocol.js';

const vectors = JSON.parse(readFileSync(new URL('../shared/command-vectors.json', import.meta.url), 'utf8'));
const accepted = new Set(vectors.filter((v) => v.expect !== null).map((v) => v.expect));
const bytes = (obj) => new TextEncoder().encode(JSON.stringify(obj));

test('i comandi generati sono tutti accettati dal Mac', () => {
  const built = [
    commands.hello('4821'), commands.resume('0123456789abcdef0123456789abcdef'), commands.next(), commands.prev(),
    commands.first(), commands.goTo(7), commands.goTo(1), commands.start(), commands.startFrom(5),
    commands.startFrom(1), commands.stop(), commands.black(), commands.reload(),
  ];
  for (const text of built) assert.ok(accepted.has(text), `${text} non è nei vettori validi`);
});

test('startFrom: dalla slide 1 è un avvio normale', () => {
  assert.equal(commands.startFrom(1), 'start');
  assert.equal(commands.startFrom(4), 'start:4');
  assert.throws(() => commands.startFrom(0));
});

test('goTo rifiuta numeri non validi', () => {
  assert.throws(() => commands.goTo(0));
  assert.throws(() => commands.goTo(1.5));
  assert.throws(() => commands.goTo(10000));
});

test('isValidPin segue le stesse regole del Mac', () => {
  for (const v of vectors.filter((x) => x.text.startsWith('hello:'))) {
    assert.equal(isValidPin(v.text.slice(6)), v.expect !== null, v.text);
  }
});

test('isValidToken segue le stesse regole del Mac', () => {
  for (const v of vectors.filter((x) => x.text.startsWith('resume:'))) {
    assert.equal(isValidToken(v.text.slice(7)), v.expect !== null, v.text);
  }
  assert.throws(() => commands.resume('corto'));
});

test('decodeMessage scarta testo non JSON o senza tipo', () => {
  assert.equal(decodeMessage(new TextEncoder().encode('nope')), null);
  assert.equal(decodeMessage(bytes({ ciao: 1 })), null);
  assert.deepEqual(decodeMessage(bytes({ t: 'auth', ok: true })), { t: 'auth', ok: true });
});

const deck = {
  t: 'deck', key: 'k#3', name: 'Prova',
  slides: [
    { title: 'Uno', notes: 'nota 1', hidden: false, id: 11 },
    { title: '', notes: 'nota 2', hidden: true, id: 12 },
    { title: 'Tre', notes: '', hidden: false, id: 13 },
  ],
};
const show = { t: 'state', ppt: true, running: true, slide: 1, count: 3, black: false, elapsed: 12, key: 'k#3', slideId: 11 };

test('applyMessage restituisce un nuovo stato senza toccare il precedente', () => {
  const s0 = initialState();
  const s1 = applyMessage(s0, deck, 1000);
  assert.equal(s0.deck, null);
  assert.equal(s1.deck.name, 'Prova');
  const s2 = applyMessage(s1, show, 2000);
  assert.equal(s1.show, null);
  assert.equal(s2.show.slide, 1);
  assert.equal(s2.showReceivedAt, 2000);
});

test('auth ok / rifiutata / bloccata', () => {
  const ok = applyMessage(initialState(), { t: 'auth', ok: true, token: 'abc' });
  assert.equal(ok.auth, 'ok');
  assert.equal(ok.token, 'abc');
  assert.equal(applyMessage(initialState(), { t: 'auth', ok: false }).auth, 'rejected');
  const locked = applyMessage(initialState(), { t: 'auth', ok: false, retryIn: 42 });
  assert.equal(locked.auth, 'locked');
  assert.equal(locked.retryIn, 42);
});

test('errore salvato con orario', () => {
  const s = applyMessage(initialState(), { t: 'err', msg: 'PowerPoint non è aperto' }, 5000);
  assert.deepEqual(s.error, { msg: 'PowerPoint non è aperto', at: 5000 });
});

test('slide corrente e prossima visibile (salta le nascoste)', () => {
  const s = applyMessage(applyMessage(initialState(), deck, 0), show, 0);
  assert.equal(currentSlide(s).notes, 'nota 1');
  assert.equal(nextVisibleSlide(s).index, 3);
  const last = applyMessage(s, { ...show, slide: 3 }, 0);
  assert.equal(nextVisibleSlide(last), null);
});

test('le note non si mostrano se il deck non corrisponde allo stato', () => {
  const s = applyMessage(applyMessage(initialState(), deck, 0), { ...show, key: 'altro#3' }, 0);
  assert.equal(currentSlide(s), null);
  assert.equal(notesStatus(s), 'loading');
});

test('slide riordinate: le note vecchie non vengono mostrate', () => {
  const s = applyMessage(applyMessage(initialState(), deck, 0), { ...show, slide: 1, slideId: 13 }, 0);
  assert.equal(currentSlide(s), null);
  assert.equal(notesStatus(s), 'stale');
});

test('schermata finale della presentazione', () => {
  const s = applyMessage(applyMessage(initialState(), deck, 0), { ...show, slide: 0, slideId: 0 }, 0);
  assert.equal(notesStatus(s), 'ended');
  assert.equal(currentSlide(s), null);
  assert.equal(nextVisibleSlide(s), null, 'niente «Dopo: 1» a fine presentazione');
});

test('stati delle note', () => {
  assert.equal(notesStatus(initialState()), 'idle');
  const notRunning = applyMessage(applyMessage(initialState(), deck, 0), { ...show, running: false }, 0);
  assert.equal(notesStatus(notRunning), 'idle');
  const ok = applyMessage(applyMessage(initialState(), deck, 0), show, 0);
  assert.equal(notesStatus(ok), 'ok');
});

test('titolo di ripiego per slide senza titolo', () => {
  assert.equal(slideTitle({ title: '' }, 2), 'Slide 2');
  assert.equal(slideTitle({ title: 'Ciao' }, 2), 'Ciao');
});

test('tempo trascorso avanza solo a presentazione avviata', () => {
  const running = applyMessage(initialState(), show, 10_000);
  assert.equal(Math.round(elapsedSeconds(running, 15_000)), 17);
  const stopped = applyMessage(initialState(), { ...show, running: false }, 10_000);
  assert.equal(elapsedSeconds(stopped, 15_000), 0);
});
