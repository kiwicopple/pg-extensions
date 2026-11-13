import test from 'node:test';
import assert from 'node:assert/strict';
import { codePointIndex, utf16Index, checkStorable } from '../src/utf16.js';
import { mulberry32 } from './helpers.js';

test('codePointIndex counts code points, not UTF-16 units', () => {
  const s = 'a\u{1F600}b\u{1F44D}\u{1F3FD}c'; // a 😀 b 👍🏽 c
  assert.equal(s.length, 9);
  assert.equal(codePointIndex(s, 0), 0);
  assert.equal(codePointIndex(s, 1), 1);
  assert.equal(codePointIndex(s, 3), 2);
  assert.equal(codePointIndex(s, 4), 3);
  assert.equal(codePointIndex(s, 6), 4); // between the thumb and its skin tone: two code points
  assert.equal(codePointIndex(s, 8), 5);
  assert.equal(codePointIndex(s, 9), 6);
  assert.equal(codePointIndex('', 0), 0);
});

test('codePointIndex refuses an index inside a surrogate pair or out of range', () => {
  const s = 'a\u{1F600}b';
  assert.throws(() => codePointIndex(s, 2), /splits a surrogate pair/);
  assert.throws(() => codePointIndex(s, -1), RangeError);
  assert.throws(() => codePointIndex(s, 5), RangeError);
  assert.throws(() => codePointIndex(s, 1.5), RangeError);
  assert.throws(() => codePointIndex(s, '1'), RangeError);
});

test('utf16Index is the inverse of codePointIndex', () => {
  const s = 'a\u{1F600}b\u{1F44D}\u{1F3FD}c';
  assert.deepEqual([0, 1, 2, 3, 4, 5, 6].map((k) => utf16Index(s, k)), [0, 1, 3, 4, 6, 8, 9]);
  assert.throws(() => utf16Index(s, 7), RangeError);
  assert.throws(() => utf16Index(s, -1), RangeError);
});

test('random strings: both conversions agree with Array.from', () => {
  const pool = ['a', 'Z', ' ', '\n', 'é', 'é', '\u{1F600}', '\u{1F468}‍\u{1F469}', '\u{10FFFF}', '�', '中', '$'];
  const rng = mulberry32(7);
  for (let n = 0; n < 300; n++) {
    let s = '';
    const len = Math.floor(rng() * 20);
    for (let k = 0; k < len; k++) s += pool[Math.floor(rng() * pool.length)];
    const cps = Array.from(s);
    let u = 0;
    for (let k = 0; k <= cps.length; k++) {
      assert.equal(codePointIndex(s, u), k);
      assert.equal(utf16Index(s, k), u);
      if (k < cps.length) u += cps[k].length;
    }
  }
});

test('lone surrogates count as one code point each (as Array.from does)', () => {
  const s = 'a\uD800b\uDC00';
  assert.equal(codePointIndex(s, 4), Array.from(s).length);
  assert.equal(utf16Index(s, 2), 2);
});

test('checkStorable refuses what Postgres cannot hold', () => {
  checkStorable('ok \u{1F600} \u{10FFFF}');
  checkStorable('');
  assert.throws(() => checkStorable('a\uD800'), /lone surrogate at index 1/);
  assert.throws(() => checkStorable('\uDC00a'), /lone surrogate at index 0/);
  assert.throws(() => checkStorable('\uD800𐀀'), /lone surrogate at index 0/);
  assert.throws(() => checkStorable('a\u0000'), /U\+0000/);
  assert.throws(() => checkStorable(5), TypeError);
});
