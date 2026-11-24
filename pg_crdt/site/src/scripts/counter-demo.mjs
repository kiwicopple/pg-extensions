import { REPLICAS, MAX_TOTAL, empty, merge, value, deltaFromCopies } from '../../../demo/counter.mjs';
import { readCounterResponse } from '../../../demo/response.mjs';

class CounterDemo extends HTMLElement {
  connectedCallback() {
    if (this.started) return;
    this.started = true;
    this.copies = Object.fromEntries(REPLICAS.map((key) => [key, empty()]));
    this.stored = empty();
    this.mode = 'loading';
    this.busy = true;
    this.lastDelta = null;
    this.addEventListener('click', (event) => {
      const button = event.target.closest('button');
      if (!button || button.disabled) return;
      if (button.hasAttribute('data-edit')) this.edit(button.dataset.edit, button.dataset.map);
      if (button.hasAttribute('data-sync')) this.sync(false);
      if (button.hasAttribute('data-replay')) this.sync(true);
      if (button.hasAttribute('data-reset')) this.start();
    });
    this.start();
  }

  find(selector) { return this.querySelector(selector); }

  message(text, error = false) {
    this.find('[data-message]').textContent = text;
    this.find('[data-message]').dataset.error = String(error);
  }

  async request(options) {
    const response = await fetch('/api/counter', { ...options, cache: 'no-store', signal: AbortSignal.timeout(12_000) });
    // A plain static preview has no API. A failed configured backend never
    // silently falls back to browser merges.
    if (response.status === 404 && !options) return { mode: 'preview' };
    return readCounterResponse(response);
  }

  async start() {
    this.busy = true;
    this.render();
    try {
      const session = await this.request();
      this.mode = session.mode;
      this.token = session.token;
      this.copies = Object.fromEntries(REPLICAS.map((key) => [key, empty()]));
      this.stored = empty();
      this.lastDelta = null;
      this.message('Try +3 on Alice’s laptop and −1 on Bob’s phone, then sync.');
    } catch (error) {
      if (this.mode === 'loading') this.mode = 'unavailable';
      this.message(error.message || 'The demo could not connect. Use Start over to try again.', true);
    } finally {
      this.busy = false;
      this.render();
    }
  }

  edit(name, map) {
    const key = `demo:${name}`;
    const state = this.copies[key];
    state[map][key] = (state[map][key] ?? 0) + 1;
    this.message('These edits are local. Sync both devices to combine their changes.');
    this.render();
  }

  async sync(replay) {
    const delta = replay ? this.lastDelta : deltaFromCopies(this.copies);
    this.busy = true;
    this.message(replay ? 'Replaying the same running totals…' : 'Merging the devices’ running totals…');
    this.render();
    try {
      const before = value(this.stored);
      const result = this.mode === 'postgres'
        ? await this.request({ method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${this.token}` }, body: JSON.stringify({ delta }) })
        : { state: merge(this.stored, delta) };
      this.stored = result.state;
      // Merge back, rather than replace: edits made during the request survive.
      for (const key of REPLICAS) this.copies[key] = merge(this.copies[key], this.stored);
      this.lastDelta = delta;
      const pending = this.hasPending();
      this.message(replay
        ? `Replayed. The merged value is still ${value(this.stored)} (was ${before}). No update was counted twice.${pending ? ' New local edits are waiting to sync.' : ''}`
        : pending ? 'Merged. Edits made during the request are still local; sync again to send them.'
          : `All copies agree: ${value(this.stored)}. Replay the last sync to see why retries are safe.`);
    } catch (error) {
      this.message(error.name === 'TimeoutError' ? 'Sync timed out. Your local edits are safe; retrying will not double-count them.' : error.message, true);
    } finally {
      this.busy = false;
      this.render();
    }
  }

  hasPending(key) {
    return (key ? [key] : REPLICAS).some((id) => ['p', 'n'].some((map) => (this.copies[id][map][id] ?? 0) > (this.stored[map][id] ?? 0)));
  }

  render() {
    const ready = ['preview', 'postgres'].includes(this.mode);
    const badge = this.find('[data-mode]');
    badge.textContent = { loading: 'Connecting…', unavailable: 'Connection unavailable', preview: 'Browser preview', postgres: 'Live Postgres' }[this.mode];
    badge.dataset.live = String(this.mode === 'postgres');
    this.find('[data-stored-label]').textContent = this.mode === 'postgres' ? 'Stored in Postgres' : 'Last merged value';
    this.find('[data-note]').textContent = this.mode === 'preview'
      ? 'Browser-only preview. Connect Postgres to run merges in the database.'
      : 'Your own demo session. Refreshing starts over; sessions expire after 24 hours.';
    for (const key of REPLICAS) {
      const name = key.split(':')[1];
      const state = this.copies[key];
      this.find(`[data-value="${name}"]`).textContent = value(state);
      this.find(`[data-totals="${name}"]`).textContent = `+${state.p[key] ?? 0} / −${state.n[key] ?? 0}`;
      this.find(`[data-replica-status="${name}"]`).textContent = this.hasPending(key) ? 'Local changes' : 'In sync';
      for (const button of this.querySelectorAll(`[data-edit="${name}"]`)) {
        button.disabled = !ready || (state[button.dataset.map][key] ?? 0) >= MAX_TOTAL;
      }
    }
    this.find('[data-stored]').textContent = value(this.stored);
    this.find('[data-json]').textContent = JSON.stringify(this.stored, null, 2);
    this.find('[data-sync]').disabled = !ready || this.busy;
    this.find('[data-replay]').disabled = !ready || this.busy || !this.lastDelta;
    this.find('[data-reset]').disabled = this.busy;
  }
}

if (!customElements.get('counter-demo')) customElements.define('counter-demo', CounterDemo);
