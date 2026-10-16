/* Dependency-free, read-only ABI reader. Every supplied string is displayed with textContent. */
"use strict";

const HooksListings = (() => {
  const selectors = Object.freeze({
    registry: "7b103999", listingCount: "a9b07c26", placementCount: "bce5c67d",
    getListing: "107a274a", getMetadata: "7477efa4", search: "0b0da480",
    featured: "0b53d080", labelKey: "cfd02839",
  });
  const word = (value) => {
    const n = BigInt(value);
    if (n < 0n || n >= (1n << 256n)) throw new Error("Invalid unsigned integer");
    return n.toString(16).padStart(64, "0");
  };
  const address = (value) => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(value) || BigInt(value) === 0n) throw new Error("Invalid contract or owner address");
    return value.toLowerCase();
  };
  class Reader {
    constructor(hex) {
      if (!/^0x([0-9a-fA-F]{64})*$/.test(hex) || hex.length > 2_000_002) throw new Error("Malformed ABI response");
      this.hex = hex.slice(2);
    }
    raw(offset) {
      if (!Number.isSafeInteger(offset) || offset < 0 || offset % 32 || (offset + 32) * 2 > this.hex.length) {
        throw new Error("ABI offset out of bounds");
      }
      return this.hex.slice(offset * 2, (offset + 32) * 2);
    }
    uint(offset) { return BigInt("0x" + this.raw(offset)); }
    offset(offset) {
      const value = this.uint(offset);
      if (value > BigInt(this.hex.length / 2)) throw new Error("ABI offset out of bounds");
      return Number(value);
    }
    addr(offset) {
      const raw = this.raw(offset);
      if (!/^0{24}/.test(raw)) throw new Error("Malformed ABI address");
      return "0x" + raw.slice(24).toLowerCase();
    }
    string(offset, max) {
      const length = this.offset(offset);
      if (length > max || (offset + 32 + length) * 2 > this.hex.length) throw new Error("Invalid string length");
      const hex = this.hex.slice((offset + 32) * 2, (offset + 32 + length) * 2);
      return new TextDecoder().decode(Uint8Array.from(hex.match(/../g) || [], (byte) => parseInt(byte, 16)));
    }
  }
  function decodeListing(hex) {
    const r = new Reader(hex);
    if (r.hex.length !== 6 * 64 || r.uint(160) > 1n) throw new Error("Unexpected listing ABI");
    return { chainId: r.uint(0), hook: r.addr(32), owner: r.addr(64), revision: r.uint(128), active: r.uint(160) === 1n };
  }
  function decodeMetadata(hex) {
    const r = new Reader(hex), base = r.offset(0);
    const getString = (field, max) => r.string(base + r.offset(base + field * 32), max);
    const labelsBase = base + r.offset(base + 9 * 32), count = r.uint(labelsBase);
    if (count > 16n) throw new Error("Too many labels");
    const labels = [];
    for (let i = 0; i < Number(count); i++) {
      labels.push(r.string(labelsBase + 32 + r.offset(labelsBase + 32 + i * 32), 32));
    }
    return {
      name: getString(0, 96), sourceRef: getString(1, 512), testRef: getString(2, 512),
      reviewRef: getString(3, 512), auditRef: getString(4, 512), callbackMask: r.uint(base + 5 * 32),
      callbackDisclosure: getString(6, 1024), feeDisclosure: getString(7, 1024),
      adminDisclosure: getString(8, 1024), labels,
    };
  }
  function decodePage(hex, placements) {
    const r = new Reader(hex), base = r.offset(0), count = r.uint(base);
    if (count > 100n) throw new Error("Oversized page");
    const items = [];
    for (let i = 0; i < Number(count); i++) {
      const at = base + 32 + i * (placements ? 11 : 1) * 32;
      if (!placements) { items.push(r.uint(at)); continue; }
      const label = r.raw(at + 10 * 32);
      if (label !== "236164" + "0".repeat(58) || r.uint(at + 9 * 32) !== 1n) throw new Error("Invalid #ad placement");
      items.push({ id: r.uint(at), listingId: r.uint(at + 32), revision: r.uint(at + 64),
        payer: r.addr(at + 96), recipient: r.addr(at + 128), startsAt: r.uint(at + 160),
        endsAt: r.uint(at + 192), label: "#ad" });
    }
    return { items, nextCursor: r.uint(32) };
  }
  function encodeLabel(label) {
    if (!/^[a-z0-9-]{1,32}$/.test(label)) throw new Error("Label must use lowercase letters, digits or hyphens");
    const hex = Array.from(new TextEncoder().encode(label), (b) => b.toString(16).padStart(2, "0")).join("");
    return word(32) + word(label.length) + hex.padEnd(64, "0");
  }
  function cardRows(id, listing, data, placement) {
    const rows = [
      ["Listing", String(id)], ["Hook chain", String(listing.chainId)], ["Hook address (claimed)", listing.hook],
      ["Current listing owner", listing.owner], ["Revision shown", String(placement ? placement.revision : listing.revision)],
      ["Audit status", "Unverified — no audited badge"],
      ["Source reference (unverified)", data.sourceRef || "Not supplied"],
      ["Test reference (unverified)", data.testRef || "Not supplied"],
      ["Review reference (unverified)", data.reviewRef || "Not supplied"],
      ["Audit reference (unverified)", data.auditRef || "Not supplied"],
      ["Callback mask (declared)", "0x" + data.callbackMask.toString(16)],
      ["Callback disclosure", data.callbackDisclosure], ["Fee disclosure", data.feeDisclosure],
      ["Admin disclosure", data.adminDisclosure], ["Labels (user supplied)", data.labels.join(", ") || "None"],
    ];
    if (placement) rows.unshift(["Paid placement", "#ad"], ["Original payer", placement.payer],
      ["Proceeds recipient", placement.recipient], ["Ends at chain timestamp", String(placement.endsAt)]);
    return rows;
  }
  function renderCard(doc, id, listing, data, placement) {
    const article = doc.createElement("article");
    if (placement) {
      article.className = "ad";
      const badge = doc.createElement("span");
      badge.className = "badge";
      badge.textContent = "#ad";
      article.append(badge);
    }
    const title = doc.createElement("h3"), details = doc.createElement("dl");
    title.textContent = data.name;
    for (const [key, value] of cardRows(id, listing, data, placement)) {
      const dt = doc.createElement("dt"), dd = doc.createElement("dd");
      dt.textContent = key; dd.textContent = value;
      details.append(dt, dd);
    }
    article.append(title, details);
    return article;
  }
  return { selectors, word, address, Reader, decodeListing, decodeMetadata, decodePage, encodeLabel, cardRows, renderCard };
})();

if (typeof module !== "undefined") module.exports = HooksListings;
if (typeof document !== "undefined") {
  const api = HooksListings, byId = (id) => document.getElementById(id);
  let state, busy = false;
  async function rpc(url, method, params) {
    if (!url) {
      if (!window.ethereum) throw new Error("No RPC URL or wallet provider");
      return window.ethereum.request({ method, params });
    }
    const response = await fetch(url, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal: AbortSignal.timeout(20000) });
    if (!response.ok) throw new Error("RPC HTTP error " + response.status);
    const result = await response.json();
    if (result.error) throw new Error(result.error.message || "RPC error");
    return result.result;
  }
  const call = (to, selector, args = "") => rpc(state.url, "eth_call", [{ to, data: "0x" + api.selectors[selector] + args }, state.block]);
  const readUint = async (to, selector) => new api.Reader(await call(to, selector)).uint(0);
  async function loadPage(placements) {
    const key = placements ? "adsCursor" : "listingsCursor", cursor = state[key];
    const raw = placements ? await call(state.ads, "featured", api.word(cursor) + api.word(20))
      : await call(state.registry, "search", api.word(cursor) + api.word(20) + api.word(state.filterChain)
        + api.word(state.filterOwner) + state.labelHash);
    const page = api.decodePage(raw, placements), cards = [];
    for (const item of page.items) {
      const id = placements ? item.listingId : item;
      if (placements && (item.startsAt > state.timestamp || item.endsAt <= state.timestamp)) throw new Error("Inactive placement in featured response");
      const listing = api.decodeListing(await call(state.registry, "getListing", api.word(id)));
      const revision = placements ? item.revision : listing.revision;
      const data = api.decodeMetadata(await call(state.registry, "getMetadata", api.word(id) + api.word(revision)));
      cards.push(api.renderCard(document, id, listing, data, placements ? item : null));
    }
    if (cards.length === 0) {
      const note = document.createElement("p");
      note.textContent = "No matching entries on this page.";
      cards.push(note);
    }
    byId(placements ? "featured" : "organic").replaceChildren(...cards);
    if (page.nextCursor < cursor || page.nextCursor > cursor + 20n) throw new Error("Invalid pagination cursor");
    state[key] = page.nextCursor;
  }
  function buttons() {
    byId("more-ads").disabled = busy || !state || state.adsCursor > state.adCount;
    byId("more-listings").disabled = busy || !state || state.listingsCursor > state.listingCount;
  }
  async function action(fn) {
    if (busy) return;
    busy = true; buttons();
    try { await fn(); }
    catch (error) {
      state = undefined;
      byId("featured").replaceChildren(); byId("organic").replaceChildren();
      byId("status").textContent = "Unable to read listings: " + error.message;
    }
    finally { busy = false; buttons(); }
  }
  byId("reader").addEventListener("submit", (event) => {
    event.preventDefault();
    action(async () => {
      state = undefined;
      byId("featured").replaceChildren(); byId("organic").replaceChildren();
      byId("status").textContent = "Loading chain snapshot…";
      const url = byId("rpc").value.trim(), expectedChain = BigInt(byId("chain").value);
      if (expectedChain <= 0n || BigInt(await rpc(url, "eth_chainId", [])) !== expectedChain) throw new Error("Registry chain mismatch");
      const block = await rpc(url, "eth_getBlockByNumber", ["latest", false]);
      if (!block || !/^0x[0-9a-f]+$/i.test(block.number) || !/^0x[0-9a-f]+$/i.test(block.timestamp)) throw new Error("Invalid chain snapshot");
      state = { url, block: block.number, timestamp: BigInt(block.timestamp), registry: api.address(byId("registry").value.trim()),
        ads: api.address(byId("ads").value.trim()), adsCursor: 1n, listingsCursor: 1n,
        filterChain: BigInt(byId("filter-chain").value || "0"), filterOwner: byId("filter-owner").value.trim()
          ? api.address(byId("filter-owner").value.trim()) : 0n, labelHash: "0".repeat(64) };
      const configuredRegistry = new api.Reader(await call(state.ads, "registry")).addr(0);
      if (configuredRegistry !== state.registry) throw new Error("Ads contract is bound to a different registry");
      const label = byId("filter-label").value.trim();
      if (label) state.labelHash = new api.Reader(await call(state.registry, "labelKey", api.encodeLabel(label))).raw(0);
      state.adCount = await readUint(state.ads, "placementCount");
      state.listingCount = await readUint(state.registry, "listingCount");
      await loadPage(true);
      await loadPage(false);
      byId("status").textContent = "Snapshot at registry chain " + expectedChain + ", block " + BigInt(state.block)
        + ", chain timestamp " + state.timestamp + ". Refresh for current visibility and expiry. References are unverified.";
    });
  });
  byId("more-ads").addEventListener("click", () => action(() => loadPage(true)));
  byId("more-listings").addEventListener("click", () => action(() => loadPage(false)));
}
