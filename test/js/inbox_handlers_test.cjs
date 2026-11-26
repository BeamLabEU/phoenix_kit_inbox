// Runs `priv/static/assets/phoenix_kit_inbox.js` in a fake page and presses the
// mouse on it. `node --test test/js/*.cjs`, also run by `mix test`
// (test/js_handlers_test.exs).
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const SOURCE = fs.readFileSync(
  path.join(__dirname, "../../priv/static/assets/phoenix_kit_inbox.js"),
  "utf8"
);

function page() {
  const listeners = [];
  const window = {};
  const document = { addEventListener: (type, fn) => listeners.push({ type, fn }) };
  const load = () => vm.runInNewContext(SOURCE, { window, document });

  // Fires `type` at `target`; answers how many times the default was prevented.
  const fire = (type, target) => {
    let prevented = 0;
    const event = { target, preventDefault: () => prevented++ };
    listeners.filter((l) => l.type === type).forEach((l) => l.fn(event));
    return prevented;
  };

  return { window, listeners, load, fire };
}

// An element inside (or being) an element that carries the attributes `names`.
function inside(names) {
  return { closest: (selector) => (names.includes(selector.slice(1, -1)) ? {} : null) };
}

test("the bundle defines the global js_sources/0 names, with no hooks", () => {
  const p = page();
  p.load();
  assert.strictEqual(typeof p.window.PhoenixKitInboxHooks, "object");
  assert.strictEqual(Object.keys(p.window.PhoenixKitInboxHooks).length, 0);
});

test("mousedown inside [data-pki-keep-focus] is cancelled, so the focus stays", () => {
  const p = page();
  p.load();
  assert.strictEqual(p.fire("mousedown", inside(["data-pki-keep-focus"])), 1);
});

test("mousedown elsewhere is left alone, and so is a target without closest", () => {
  const p = page();
  p.load();
  assert.strictEqual(p.fire("mousedown", inside([])), 0);
  assert.strictEqual(p.fire("mousedown", {}), 0);
  assert.strictEqual(p.fire("mousedown", null), 0);
});

test("only mousedown is listened to: the click itself goes through", () => {
  const p = page();
  p.load();
  assert.deepStrictEqual(p.listeners.map((l) => l.type), ["mousedown"]);
  assert.strictEqual(p.fire("click", inside(["data-pki-keep-focus"])), 0);
});

test("loading the bundle twice installs one listener", () => {
  const p = page();
  p.load();
  p.load();
  assert.strictEqual(p.listeners.length, 1);
});
