#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${1:-$ROOT}"

export MOMENTERM_ROOT="$ROOT"

"$ROOT/scripts/build.sh" >/dev/null
node "$ROOT/Support/monacori-bridge.mjs" build "$REPO" | node -e '
let raw = "";
process.stdin.on("data", (chunk) => raw += chunk);
process.stdin.on("end", () => {
  const review = JSON.parse(raw);
  if (!review.ok) throw new Error(review.error || "bridge failed");
  if (!review.html.includes("monacori") || !review.html.includes("diff2html-container")) {
    throw new Error("rendered HTML is not Monacori review HTML");
  }
  if (!Array.isArray(review.lazyBodies)) throw new Error("lazyBodies missing");
  if (typeof review.lazySourceData !== "string") throw new Error("lazySourceData missing");
  console.log(`smoke ok: ${review.files} files, ${review.hunks} hunks, signature ${review.signature}`);
});
'
