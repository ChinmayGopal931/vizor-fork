// An in-memory leveldown for the tests, so the engine's own Database and merkletrees run in Node over a store that
// keeps keys in order the way IndexedDB does.
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { AbstractIterator, AbstractLevelDOWN } = require('abstract-leveldown');
const { Database } = require('@railgun-community/engine');

const asStored = (data) => (Buffer.isBuffer(data) ? data.toString('binary') : String(data));
const asRead = (stored, asBuffer) => (asBuffer ? Buffer.from(stored, 'binary') : stored);

function inRange(key, { gt, gte, lt, lte }) {
  return (gt === undefined || key > gt) && (gte === undefined || key >= gte) && (lt === undefined || key < lt) && (lte === undefined || key <= lte);
}

class MemoryIterator extends AbstractIterator {
  constructor(db, options) {
    super(db);
    const keys = [...db.store.keys()].filter((key) => inRange(key, options)).sort();
    if (options.reverse) keys.reverse();
    this.keys = options.limit >= 0 ? keys.slice(0, options.limit) : keys;
    this.options = options;
  }

  _next(callback) {
    const key = this.keys.shift();
    if (key === undefined) {
      this._nextTick(callback);
      return;
    }
    const value = this.db.store.get(key);
    this._nextTick(callback, null, asRead(key, this.options.keyAsBuffer), asRead(value, this.options.valueAsBuffer));
  }
}

class MemoryDown extends AbstractLevelDOWN {
  constructor() {
    super({ bufferKeys: true, snapshots: false, permanence: false, clear: true });
    this.store = new Map();
  }

  _open(_options, callback) {
    this._nextTick(callback);
  }

  _serializeKey(key) {
    return asStored(key);
  }

  _serializeValue(value) {
    return asStored(value);
  }

  _get(key, options, callback) {
    if (!this.store.has(key)) {
      this._nextTick(callback, new Error('NotFound'));
      return;
    }
    this._nextTick(callback, null, asRead(this.store.get(key), options.asBuffer));
  }

  _put(key, value, _options, callback) {
    this.store.set(key, value);
    this._nextTick(callback);
  }

  // abstract-leveldown's own clear hands its keys over as buffers.
  _del(key, _options, callback) {
    this.store.delete(asStored(key));
    this._nextTick(callback);
  }

  _batch(operations, _options, callback) {
    for (const { type, key, value } of operations) {
      if (type === 'put') this.store.set(key, value);
      else this.store.delete(key);
    }
    this._nextTick(callback);
  }

  _iterator(options) {
    return new MemoryIterator(this, options);
  }
}

/** A fresh engine Database over memory, and the store under it (`down.store`, a Map of keys to stored values). */
export function memoryDatabase() {
  const down = new MemoryDown();
  return { db: new Database(down), down };
}
