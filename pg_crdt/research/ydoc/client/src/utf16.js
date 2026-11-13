// Position conversion between JavaScript strings (UTF-16 code units) and the
// code points that pg_crdt counts (Postgres length() and substr()).

const isHigh = (c) => c >= 0xd800 && c <= 0xdbff;
const isLow = (c) => c >= 0xdc00 && c <= 0xdfff;

/**
 * The code point index of UTF-16 index `index` in `text`: the number of code
 * points in `text.slice(0, index)`.
 *
 * @param {string} text
 * @param {number} index A UTF-16 index, 0 to `text.length`.
 * @returns {number}
 * @throws {RangeError} When `index` is out of range, or falls between the two
 *   halves of a surrogate pair (inside an emoji, for example).
 */
export function codePointIndex(text, index) {
  if (!Number.isInteger(index) || index < 0 || index > text.length) {
    throw new RangeError(`index ${index} is outside the text (length ${text.length})`);
  }
  if (index > 0 && index < text.length && isHigh(text.charCodeAt(index - 1)) && isLow(text.charCodeAt(index))) {
    throw new RangeError(`index ${index} splits a surrogate pair`);
  }
  let n = 0;
  for (let i = 0; i < index; i++) {
    if (isHigh(text.charCodeAt(i)) && i + 1 < index && isLow(text.charCodeAt(i + 1))) i++;
    n++;
  }
  return n;
}

/**
 * The UTF-16 index of code point index `cp` in `text` (the inverse of
 * `codePointIndex`).
 *
 * @param {string} text
 * @param {number} cp A code point index, 0 to the number of code points.
 * @returns {number}
 * @throws {RangeError} When `cp` is out of range.
 */
export function utf16Index(text, cp) {
  if (!Number.isInteger(cp) || cp < 0) throw new RangeError(`code point index ${cp} is out of range`);
  let i = 0;
  for (let n = 0; n < cp; n++) {
    if (i >= text.length) throw new RangeError(`code point index ${cp} is outside the text`);
    i += isHigh(text.charCodeAt(i)) && i + 1 < text.length && isLow(text.charCodeAt(i + 1)) ? 2 : 1;
  }
  return i;
}

/**
 * Throws a TypeError when `text` cannot be stored by Postgres: a lone
 * surrogate (not valid UTF-8) or U+0000 (not allowed in `text` or `jsonb`).
 * An op that carries one would be refused by the server.
 *
 * @param {string} text
 */
export function checkStorable(text) {
  if (typeof text !== 'string') throw new TypeError('text must be a string');
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c === 0) throw new TypeError(`U+0000 at index ${i}: Postgres text cannot hold it`);
    if (isHigh(c)) {
      if (i + 1 < text.length && isLow(text.charCodeAt(i + 1))) { i++; continue; }
      throw new TypeError(`lone surrogate at index ${i}`);
    }
    if (isLow(c)) throw new TypeError(`lone surrogate at index ${i}`);
  }
}
