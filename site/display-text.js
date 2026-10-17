/* Display-only escaping. Never use this representation for hashing or onchain input. */
"use strict";
function escapeDisplayText(value) {
  return String(value).replace(/[\p{Cc}\p{Cf}\p{Default_Ignorable_Code_Point}\u2028\u2029]/gu,
    ch => "\\u{" + ch.codePointAt(0).toString(16).toUpperCase() + "}");
}
if (typeof module !== "undefined") module.exports = { escapeDisplayText };
