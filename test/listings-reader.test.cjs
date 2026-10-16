"use strict";
const assert = require("node:assert/strict");
const { test } = require("node:test");
const { execFileSync } = require("node:child_process");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const ui = require("../site/listings.js");
const root = path.resolve(__dirname, "..");
const encode = (signature, ...args) => execFileSync("cast", ["abi-encode", signature, ...args],
  { cwd: root, encoding: "utf8" }).trim();
// These are local ABI vectors, never operational deployment addresses.
const hook = "0x" + "12".repeat(20), owner = "0x" + "34".repeat(20), recipient = "0x" + "56".repeat(20);
const zero = "0x" + "00".repeat(20);
const listingHex = () => encode("f((uint256,address,address,address,uint256,bool))", `(1,${hook},${owner},${zero},2,true)`);
const metadataHex = () => encode("f((string,string,string,string,string,uint160,string,string,string,string[]))",
  '("<img src=x onerror=alert(1)>","ipfs://source","ipfs://tests","ipfs://review","javascript:alert(1)",4288,"Callbacks","No fees","No admin",["swap-limit","static-fee"])');
const placementHex = (label = "0x236164", status = "1") => encode(
  "f((uint256,uint256,uint256,address,address,uint256,uint256,uint256,uint256,uint8,bytes3)[],uint256)",
  `[(1,1,1,${owner},${recipient},1800000000,1800604800,0,0,${status},${label})]`, "2");

test("browser selectors match compiler artifacts", () => {
  const listing = JSON.parse(readFileSync(path.join(root, "out/HookListingRegistry.sol/HookListingRegistry.json")));
  const ads = JSON.parse(readFileSync(path.join(root, "out/FeaturedPlacements.sol/FeaturedPlacements.json")));
  const ids = { ...listing.methodIdentifiers, ...ads.methodIdentifiers };
  const signatures = {
    registry: "registry()", listingCount: "listingCount()", placementCount: "placementCount()",
    getListing: "getListing(uint256)", getMetadata: "getMetadata(uint256,uint256)",
    search: "search(uint256,uint256,uint256,address,bytes32)", featured: "featured(uint256,uint256)", labelKey: "labelKey(string)",
  };
  for (const [name, signature] of Object.entries(signatures)) assert.equal(ui.selectors[name], ids[signature]);
});

test("decode static listing and dynamic metadata including label offsets", () => {
  const listing = ui.decodeListing(listingHex()), metadata = ui.decodeMetadata(metadataHex());
  assert.equal(listing.chainId, 1n);
  assert.equal(listing.hook, hook);
  assert.equal(listing.owner, owner);
  assert.equal(listing.revision, 2n);
  assert.equal(listing.active, true);
  assert.equal(metadata.name, "<img src=x onerror=alert(1)>");
  assert.equal(metadata.auditRef, "javascript:alert(1)");
  assert.equal(metadata.callbackMask, 4288n);
  assert.deepEqual(metadata.labels, ["swap-limit", "static-fee"]);
  assert.equal(metadata.adminDisclosure, "No admin");
});

test("decode ordered featured and organic pages with continuation cursors", () => {
  const featured = ui.decodePage(placementHex(), true);
  assert.equal(featured.nextCursor, 2n);
  assert.equal(featured.items[0].revision, 1n);
  assert.equal(featured.items[0].label, "#ad");
  assert.equal(featured.items[0].payer, owner);
  assert.equal(featured.items[0].recipient, recipient);
  assert.equal(featured.items[0].endsAt - featured.items[0].startsAt, 604800n);
  const page = ui.decodePage(encode("f(uint256[],uint256)", "[1,4,6]", "21"), false);
  assert.deepEqual(page, { items: [1n, 4n, 6n], nextCursor: 21n });
  assert.deepEqual(ui.decodePage(encode("f(uint256[],uint256)", "[]", "21"), false), { items: [], nextCursor: 21n });
});

test("every paid card visibly carries #ad and renders hostile text as text", () => {
  // A small DOM stub rejects any attempted HTML insertion while capturing visible content.
  const doc = { createElement(tag) { return { tag, children: [], textContent: "", className: "",
    append(...nodes) { this.children.push(...nodes); }, set innerHTML(_) { throw new Error("unsafe HTML insertion"); } }; } };
  const flatten = (node) => [node.textContent, ...node.children.flatMap(flatten)];
  const listing = ui.decodeListing(listingHex()), metadata = ui.decodeMetadata(metadataHex());
  const placement = ui.decodePage(placementHex(), true).items[0];
  const ad = ui.renderCard(doc, 1n, listing, metadata, placement);
  assert.equal(ad.className, "ad");
  assert.equal(ad.children[0].textContent, "#ad");
  assert.equal(ad.children[0].className, "badge");
  const text = flatten(ad);
  assert(text.includes("<img src=x onerror=alert(1)>"));
  assert(text.includes("javascript:alert(1)"));
  assert(text.includes("Unverified — no audited badge"));
  assert(text.includes("Audit reference (unverified)"));
  assert.deepEqual(ui.cardRows(1n, listing, metadata, placement).find(([key]) => key === "Revision shown"), ["Revision shown", "1"]);
  const organic = ui.renderCard(doc, 1n, listing, metadata, null);
  assert.equal(organic.className, "");
  assert(!flatten(organic).includes("#ad"));
});

test("reject malformed ABI, absent ad labels and unexpected placement status", () => {
  assert.throws(() => ui.decodeListing("0x"));
  assert.throws(() => ui.decodeMetadata("0x" + "ff".repeat(32)));
  assert.throws(() => ui.decodePage(placementHex("0x000000"), true), /#ad/);
  assert.throws(() => ui.decodePage(placementHex("0x236164", "2"), true), /#ad/);
  assert.throws(() => ui.decodeMetadata(metadataHex().slice(0, -64)));
  assert.throws(() => ui.word(-1));
  assert.throws(() => ui.word(1n << 256n));
  assert.throws(() => ui.address(zero));
  assert.throws(() => ui.address("not an address"));
});

test("label encoding matches independent ABI encoder and rejects noncanonical search text", () => {
  assert.equal("0x" + ui.encodeLabel("static-fee"), encode("f(string)", "static-fee"));
  for (const label of ["", "Static-fee", "has space", "#ad", "a".repeat(33)]) assert.throws(() => ui.encodeLabel(label));
});
