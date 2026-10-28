import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { encodeFrames, parseFrame, addFrame, emptyBuffers } from '../web/js/framing.js';

const vectors = JSON.parse(readFileSync(new URL('../shared/framing-vectors.json', import.meta.url), 'utf8'));
const toHex = (bytes) => Buffer.from(bytes).toString('hex');
const fromHex = (hex) => new Uint8Array(Buffer.from(hex, 'hex'));
const utf8 = (text) => new TextEncoder().encode(text);

for (const v of vectors) {
  test(`encodeFrames coincide con il vettore "${v.name}"`, () => {
    const frames = encodeFrames(utf8(v.payload), v.messageId, v.maxFrameSize);
    assert.deepEqual(frames.map(toHex), v.frames);
  });

  test(`riassemblaggio del vettore "${v.name}" (anche UTF-8 spezzato)`, () => {
    const result = v.frames.map(fromHex).reduce(
      (acc, frame) => {
        const next = addFrame(acc.buffers, frame);
        return { buffers: next.buffers, messages: next.message ? [...acc.messages, next.message] : acc.messages };
      },
      { buffers: emptyBuffers(), messages: [] },
    );
    assert.equal(result.messages.length, 1);
    assert.equal(new TextDecoder().decode(result.messages[0]), v.payload);
    assert.equal(result.buffers.size, 0, 'nessun buffer pendente dopo il messaggio completo');
  });
}

test('frame fuori ordine e duplicati vengono gestiti', () => {
  const frames = encodeFrames(utf8('abcdefghij'), 3, 8); // 3 byte per frame → 4 frame
  const order = [frames[2], frames[0], frames[0], frames[3], frames[1]];
  const final = order.reduce((acc, f) => {
    const next = addFrame(acc.buffers, f);
    return { buffers: next.buffers, message: next.message ?? acc.message };
  }, { buffers: emptyBuffers(), message: null });
  assert.equal(new TextDecoder().decode(final.message), 'abcdefghij');
});

test('due messaggi intrecciati si ricompongono separatamente', () => {
  const a = encodeFrames(utf8('primo messaggio'), 1, 9);
  const b = encodeFrames(utf8('secondo'), 2, 9);
  const mixed = [a[0], b[0], a[1], b[1], a[2], a[3]];
  const messages = [];
  mixed.reduce((buffers, f) => {
    const next = addFrame(buffers, f);
    if (next.message) messages.push(new TextDecoder().decode(next.message));
    return next.buffers;
  }, emptyBuffers());
  assert.deepEqual(messages.sort(), ['primo messaggio', 'secondo']);
});

test('addFrame non modifica i buffer ricevuti', () => {
  const frames = encodeFrames(utf8('immutabile!'), 5, 8);
  const before = emptyBuffers();
  const after = addFrame(before, frames[0]).buffers;
  assert.equal(before.size, 0);
  assert.equal(after.size, 1);
  const after2 = addFrame(after, frames[1]).buffers;
  assert.equal(after.get(5).received, 1);
  assert.equal(after2.get(5).received, 2);
});

test('frame non validi vengono ignorati', () => {
  assert.equal(parseFrame(new Uint8Array([1, 2])), null);
  assert.equal(parseFrame(new Uint8Array([1, 0, 5, 0, 2])), null, 'indice oltre il totale');
  assert.equal(parseFrame(new Uint8Array([1, 0, 0, 0, 0])), null, 'totale zero');
  const result = addFrame(emptyBuffers(), new Uint8Array([9]));
  assert.equal(result.message, null);
  assert.equal(result.buffers.size, 0);
});

test('i messaggi incompleti più vecchi vengono scartati oltre il limite', () => {
  const buffers = [10, 11, 12, 13, 14, 15].reduce(
    (acc, id) => addFrame(acc, encodeFrames(utf8('xxxxxxxx'), id, 8)[0]).buffers,
    emptyBuffers(),
  );
  assert.ok(buffers.size <= 4);
  assert.ok(!buffers.has(10));
  assert.ok(buffers.has(15));
});
