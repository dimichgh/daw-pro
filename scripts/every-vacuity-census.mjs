// m23-ee-1 — the `every()`-VACUITY CENSUS.
//
// THE AXIS: `[].every(fn)` returns `true`. An assertion of the form
// `ck("… in EVERY sample", coll.every(…))` over a RUNTIME-DERIVED collection
// passes VACUOUSLY when that collection is empty. Same for `.some()` inverted,
// and for `.filter(…).length === 0` ("no bad rows" passes when there were no rows).
//
// WHY A REAL PARSER AND NOT A GREP: the filed scope (115 occurrences / 39 gates)
// counts `.every(` ANYWHERE INCLUDING COMMENT PROSE — the same contamination that
// once made a `process.env.PORT` count read 5 when live code had 0. Acorn sees
// code only. It also gives the two things a regex cannot: paren-accurate argument
// containment (across nested calls, arrow bodies, template literals) and scope
// resolution for the receiver, which is the ACTUAL discriminator this item turns on.
//
// ⚠️ THIS SCRIPT DELIBERATELY DOES NOT PRINT A VERDICT OR A BARE COUNT.
// The item's own words: "demand the LIST of runtime-derived collections with the
// clearing reason for each, never a bare verdict". That applies to my own tooling.
// A script that prints "37 at-risk sites" reproduces the exact shape that makes an
// unreadable corpus indistinguishable from a clean one. It emits one ROW PER SITE.
//
// ⚠️ IT ALSO DOES NOT HARD-CODE THE ASSERTION-HELPER NAMES. The corpus uses at
// least t/check/checks/ck/expect/ok/leg — a guessed list under-reports silently.
// The scanner reports whatever callee encloses the site and I classify afterwards.

// ─────────────────────────────────────────────────────────────────────────────
// RUNNING IT (m23-ee-1, 2026-08-09). Needs `acorn` + `acorn-walk`, which are
// DELIBERATELY NOT a repo dependency — this is a periodic audit, not part of any
// gate, and adding two packages to `mcp-server/package.json` for it would put a
// dependency on the shipped surface to serve a one-off sweep. Install them
// OUT OF TREE and point ACORN_DIR at that directory:
//
//     mkdir -p /tmp/vac && cd /tmp/vac && npm i acorn acorn-walk
//     ACORN_DIR=/tmp/vac node scripts/every-vacuity-census.mjs > census.json
//     EE_GATES=<dir> ...   # scan a different gate directory (used for the control)
//
// It prints JSON to stdout: {rows, parseFails, filesScanned, notCleared,
// notClearedByProvenance} (the last field added at m23-ee-2c — see below). It
// prints NO verdict, on purpose — see the note below.
//
// ⚠️ `notCleared` was added at the m23-ee-2b close, and it is the ONE count this
// tool emits. Reason: consumers were filtering `rows` themselves, and a consumer
// that guesses the field name wrong gets a CONFIDENT ZERO — a filter that never
// matched is indistinguishable from a clean corpus. That happened: a query for
// `r.atRisk` (there is no such field; it is `r.cleared`) printed "AT-RISK TOTAL: 0"
// when the real answer was 16. The tool knows its own schema, so the tool does the
// count. **Read `notCleared`; do not re-derive it.** If you must filter by hand the
// predicate is `r.cleared === false`, and check `parseFails.length === 0` beside it —
// a blank-looking sibling field is the tell that your field names are wrong.
//
// `notCleared` is NOT the actionable count: a receiver that is a helper PARAMETER
// is interprocedural and clears by inspection, not by this tool (`m23do:163` is the
// standing example). Actionable = notCleared − those. Reconcile from two directions.
//
// ⚠️⚠️ KNOWN FALSE FLAGS AS OF 2026-08-11 (the m23-gm close) — READ THIS BEFORE
// TRIAGING A RISE IN `notCleared`. Tightening idiom A at m23-gm moved `notCleared`
// 6 → 12, and FIVE of the six new flags are KNOWN-SOUND, not finds. They live in
// m23g1-arrange-multiselect, m23ak-note-selection-drop, m23x-arrow-nudge (two), and
// m23g2-group-drag. All five prove non-emptiness by a route this tool does not yet
// model: they do not ASSERT a length, they INDEX the receiver and dereference it, so
// an empty collection THROWS and the check fails LOUDLY rather than passing
// vacuously. **Roadmap m23-gn teaches this idiom and will clear them again.** The
// SIXTH new flag (in m23x-arrow-nudge, the `trimmedIds`/`removedIds` leg) is a REAL
// vacuous leg and is roadmap m23-go. ⚠️ Deliberately NO `file:line` list here —
// line numbers in these gates drift and a stale coordinate list is worse than none;
// the roadmap items carry the exact coordinates, and this note carries the shape.
// ⭐ WHEN m23-gn AND m23-go BOTH LAND, DELETE THIS PARAGRAPH — a "known false
// flags" note that outlives its cause teaches the next reader to ignore real finds.
//
// ⚠️ `notClearedByProvenance` was added at m23-ee-2c: {rows, parseFails,
// filesScanned, notCleared, notClearedByProvenance}. It buckets the `notCleared`
// rows by `provenance` so a consumer doesn't have to re-derive the breakdown by
// filtering `rows` (see the `r.atRisk` incident above — same failure mode, new
// field). The `HELPER-RETURN` bucket is receivers that come from a call to a
// function declared in THIS FILE (`m23ak:305/553`'s `starts(ids)` is the standing
// example) — genuinely `cleared: false` (this tool does not resolve helper
// bodies — that is out of scope, see localHelperCall()'s header comment) but
// distinguishable from an open unknown: it means "go read one function", not
// "trace an external API". `notClearedByProvenance["HELPER-RETURN"]` is exactly
// how many of `notCleared` are that easier case.
//
// ⚠️ `HELPER-PARAM` was added at m23-ee-2c-2b (enclosingParamOwner(), below) —
// the MIRROR of `HELPER-RETURN`, one call direction over: a receiver that IS
// the immediately-enclosing function's own parameter (`m23do:163`'s `needle`
// is the standing example, referenced by name two paragraphs up before this
// tool could actually say so). Also genuinely `cleared: false` (this tool
// cannot see across the call boundary to know what every CALLER passes) but
// also "go read one function" rather than a true unknown — reconcile the
// actionable count against BOTH buckets, not just HELPER-RETURN.
// ─────────────────────────────────────────────────────────────────────────────
const ACORN_DIR = process.env.ACORN_DIR || "./node_modules";
const acorn = await import(`${ACORN_DIR}/acorn/dist/acorn.mjs`);
const walk = await import(`${ACORN_DIR}/acorn-walk/dist/walk.mjs`);
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

const GATES = process.env.EE_GATES || "/Users/dsemenov/Views/daw-pro/scripts/gates";

const src = (n) => readFileSync(path.join(GATES, n), "utf8");
const txt = (code, node) => code.slice(node.start, node.end).replace(/\s+/g, " ");

// The ROOT identifier a member chain hangs off: `a.b.c.every(...)` -> `a`.
function rootIdent(node) {
  let n = node;
  for (;;) {
    if (n.type === "MemberExpression") n = n.object;
    else if (n.type === "CallExpression") n = n.callee;
    else if (n.type === "ChainExpression") n = n.expression;
    else if (n.type === "TSNonNullExpression") n = n.expression;
    else break;
  }
  return n.type === "Identifier" ? n.name : null;
}

// `map` is the only length-preserving op this corpus is trusted to reason
// about — `filter`/`slice`/`flatMap`/`splice` can all shrink a collection, so
// treating any of those as length-preserving would be an OVER-clearing bug,
// not a fix. Module-scope: shared by classifyInit's own inline-literal-chain
// check below AND by lengthPreservingChainBase() (blind spot 2, further down).
const LEN_PRESERVING = new Set(["map"]);

// Where did the receiver come from? This is the discriminator: a `const X = [...]`
// literal can never be runtime-empty; anything awaited, called, or read off the
// filesystem/app can be.
function classifyInit(init, code) {
  if (!init) return ["UNKNOWN", "declared without an initialiser"];
  switch (init.type) {
    case "ArrayExpression":
      // `const X = []` is only a candidate if emptiness is actually REACHABLE.
      // An accumulator filled by a FIXED-BOUND loop with an unconditional push
      // has a length known at authoring time. Resolved by the caller, which has
      // the identifier and the AST; see fixedFillCount().
      return init.elements.length === 0
        ? ["EMPTY-LITERAL", "literal EMPTY array — filled later; emptiness reachable UNLESS the fill is fixed-bound"]
        : ["LITERAL", `array literal, ${init.elements.length} element(s) — cannot be runtime-empty`];
    case "AwaitExpression":
      return ["RUNTIME", `awaited: ${txt(code, init).slice(0, 60)}`];
    case "CallExpression": {
      // ⚠️ A CHAIN OFF A NON-EMPTY ARRAY LITERAL IS STILL NON-EMPTY, PROVIDED
      // EVERY LINK PRESERVES LENGTH. `["limiter","compressor","bassEnhancer"].map(f)`
      // has exactly 3 elements and can never go vacuous, so flagging it is a false
      // positive — and false positives are what make a census get ignored.
      // `map` preserves length; `filter`/`slice`/`flatMap`/`splice` do NOT.
      // (LEN_PRESERVING is module-scope now — shared with lengthPreservingChainBase()
      // below, used by the blind-spot-2 transitive resolution.)
      let n = init, ops = [];
      while (n.type === "CallExpression" && n.callee.type === "MemberExpression") {
        ops.push(n.callee.property.name);
        n = n.callee.object;
      }
      if (n.type === "ArrayExpression" && n.elements.length > 0 && ops.every((o) => LEN_PRESERVING.has(o))) {
        return ["LITERAL", `${ops.join("/")} over a ${n.elements.length}-element array literal — length-preserving, cannot be empty`];
      }
      const c = txt(code, init.callee).slice(0, 40);
      if (/^JSON\.parse/.test(c)) return ["RUNTIME", `JSON.parse(...)`];
      if (/readdirSync|readFileSync|globSync/.test(c)) return ["RUNTIME", `filesystem read: ${c}`];
      return ["RUNTIME", `call: ${c}(...)`];
    }
    case "MemberExpression":
      return ["RUNTIME", `member read: ${txt(code, init).slice(0, 60)}`];
    case "ConditionalExpression":
      return ["RUNTIME", `conditional: ${txt(code, init).slice(0, 60)}`];
    case "Identifier":
      return ["ALIAS", `aliases \`${init.name}\``];
    default:
      return ["RUNTIME", `${init.type}: ${txt(code, init).slice(0, 60)}`];
  }
}

// ⚠️⚠️ THERE ARE **TWO** CLEARING IDIOMS IN THIS CORPUS, NOT ONE, AND THE
// POSITIVE CONTROL IS WHAT PROVED IT. A first cut of this scanner knew only the
// INLINE conjunct, so it re-flagged all four m23c2 legs that m23-bj had ALREADY
// FIXED — i.e. it would have reported a fixed gate as still-defective, and (worse,
// symmetrically) would report any gate cleared the same way as at-risk forever.
//
//   IDIOM A — inline conjunct, same expression:
//      bundlePaths.length > 0 && bundlePaths.every(…)          (m23ay:353)
//      drawn.length === 3    && drawn.every(…)                 (m23p2:102)
//   IDIOM B — a separate LEADING COUNT-PIN LEG in the same block:
//      check("L1 samples: the run produced enough frames …",
//            s.length >= 5, `${s.length} samples`);            (m23c2:378)
//      check("L1 arrange: … in EVERY sample", s.every(…));     (m23c2:380)
//
// Idiom B is the shape the item itself calls settled and says to copy, so a
// scanner blind to it is measuring the wrong thing. Both are checked below.
// m23-gm — AST-based match, replacing the old regex-over-source-text scan
// (`\\brecvRoot\\b[^;]{0,80}\\.length`), which had THREE compounding faults:
//
// ① SELF-MATCH — `parts` used to include the conjunct/branch that CONTAINS
// THE SITE ITSELF, so a site's own callback body could satisfy its own
// guard (`ok === true && after.every((c) => near(c.lengthBeats, LEN))`
// "cleared", with the recorded guard being the `.every()` call itself).
// Fixed by excluding any part whose span [start,end) contains the site's
// own span — this generalises across arbitrarily deep `&&` chains (each
// level of the climb re-applies the same exclusion to whichever part still
// contains the site) and across the ConditionalExpression shape too
// (whichever of test/consequent/alternate holds the site — a single
// span-containment check covers both shapes uniformly, no special-casing
// needed).
//
// ② PREFIX MATCH — a bare `\.length` substring test matched `.lengthBeats`
// (a real, pervasive clip property in this corpus) as a prefix. Fixed by
// requiring an actual MemberExpression with `property.name === "length"`
// (non-computed), found via a proper subtree walk rather than a text scan.
//
// ③ ROOT-ONLY MATCH — the exact axis m23-gl fixed for idiom B, one file
// section up: a guard's root identifier matching is not enough, since
// `res.clips.length` says nothing about `res.landings.every(…)`. When
// `recvPath` is given (the SITE's own receiver could be structurally
// described via memberPath()), a candidate `.length` MemberExpression's own
// object path must equal it EXACTLY; an undescribable candidate path is a
// REJECTION, not a fallback — same stance countPinInStmt() takes, and for
// the same reason: this is a CLEARING rule, and `recvPath` is known here, so
// a candidate that cannot be shown to describe the SAME thing has not
// earned the clear. `recvPath` is only ever non-null for the site's own
// un-hopped receiver (see the call site, far below) — a derivation-chain
// hop has no single receiver expression left to compare against
// (derivationChain()'s own header) and passes `null`, which skips this axis
// entirely, unchanged from before.
function findLengthGuard(ancestors, recvRoot, code, site, recvPath) {
  for (let i = ancestors.length - 1; i >= 0; i--) {
    const a = ancestors[i];
    if (a.type === "LogicalExpression" || a.type === "ConditionalExpression") {
      const parts = a.type === "LogicalExpression" ? [a.left, a.right] : [a.test, a.consequent, a.alternate];
      for (const p of parts) {
        if (!p) continue;
        if (p.start <= site.start && site.end <= p.end) continue;   // ① — this part contains the site itself
        let found = null;
        walk.simple(p, {
          MemberExpression(m) {
            if (found || m.computed || m.property.type !== "Identifier" || m.property.name !== "length") return;   // ②
            if (rootIdent(m.object) !== recvRoot) return;
            if (recvPath) {
              const candPath = memberPath(m.object);
              if (!candPath || !pathsEqual(candPath, recvPath)) return;   // ③
            }
            found = m;
          },
        });
        if (found) return txt(code, p).slice(0, 80);
      }
    }
    // Stop climbing at a function boundary — a guard outside it is not the same expression.
    if (/Function/.test(a.type)) break;
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────
// m23-ex — REAL LEXICAL SCOPE RESOLUTION for findCountPin()'s idiom-B match.
//
// THE DEFECT THIS FIXES: findCountPin()'s statement scan (below) matches a
// candidate pin by NAME ONLY (`rootIdent(len.object) === recvRoot`). It also
// (necessarily, for idiom B to reach a preceding sibling block at all — see
// the m23-eu comment on prevReassignment(), further down) climbs OUTWARD
// through enclosing Program/BlockStatement levels and, at each level, calls
// countPinInStmt() on WHOLE SIBLING STATEMENTS — including sibling bare
// `{ }` blocks it did not itself descend into. `m23aj2-move-wire.mjs` has
// two separate `const landings = res.landings ?? [];` in non-overlapping
// sibling blocks (:75-92 and :195-212); scanning the try-body level for a
// pin on `:208`'s `landings` walks INTO the sibling `:75-92` block (a whole
// statement that "starts before" :208) and matches `landings.length === 2`
// at :86 — a BinaryExpression that happens to share the name `landings`,
// but whose `landings` is a COMPLETELY DIFFERENT `const` binding. Name-only
// matching cannot tell these apart; the reassignment-epoch bound (m23-eu,
// prevReassignment/nextReassignment below) cannot either, because a `const`
// redeclaration in a sibling block is not a reassignment of anything — it
// is invisible to reassignment tracking by construction.
//
// THE FIX: resolve the SITE's own `recvRoot` to its actual declaring AST
// node via a real (if deliberately bounded) scope walk — nearest enclosing
// BLOCK wins for `let`/`const`/function-decl/class-decl and for-of/for-in/
// for(let…)/catch bindings; nearest enclosing FUNCTION (or Program, at the
// top) wins for `var` and for parameters — and require every candidate pin
// found by the statement scan to resolve `recvRoot` to that SAME node, by
// object identity, not by name. Two `const landings` in sibling blocks are
// two distinct VariableDeclarator objects even though acorn assigns them
// the same name, so this rejects the cross-block match while leaving every
// same-scope idiom-B pin (the case this idiom exists to serve) untouched —
// same-binding identity holds trivially when the pin and the site share an
// enclosing block, however far that block's OWN ancestor chain climbs
// (confirmed on `m23y-track-select.mjs:473`'s nested `.every` inside
// `.every`, whose pin sits in the SAME `&&` expression as the site itself
// but past two ArrowFunctionExpression closures with no `probeClips` param
// of their own — genuinely the same closed-over `const`, correctly still
// clears).
//
// FAILS TOWARD FLAGGING, per this file's standing rule for every
// conservative branch: a name this resolver cannot place in ANY scope on
// the path — a destructuring pattern, an import, a shape not modelled here
// — makes findCountPin() refuse the whole lookup rather than guess, and
// records that refusal in the row's own `pinScope` field (see the
// `notCleared`-header discipline: a null field must be visible as null, not
// silently indistinguishable from "no pin was ever looked for").
//
// SCOPED DELIBERATELY NARROW, matching this file's own established taste
// for a conservative census over a general dataflow analysis: plain
// `Identifier` declarators/params only (no destructuring/rest — an
// unresolvable name is the conservative, correct answer for those, not a
// wrong guess); `SwitchStatement` cases share ONE block scope (modelled,
// since two gates in this corpus use `switch`, even though neither currently
// has a `let`/`const` case body a `.every`/`.some`/`filter()` site could
// need — checked, not assumed); `var` hoisting is modelled with a bounded
// recursive descent that refuses to cross a NESTED function boundary.
//
// m23-gl — FIXED (was a known, deliberately-unfixed gap, distinct from the
// one m23-ex closed): countPinInStmt() used to match a candidate on
// `rootIdent(len.object)` alone, so `res.clips.length === 2` could still
// "pin" a DIFFERENT property read off the very same `res`
// (`res.landings.every(…)`) — a property-level over-clear, not a
// binding-level one. Binding identity (m23-ex) cannot catch this by
// construction (both reads resolve to the SAME `res` binding); it needed a
// separate check, one property-path axis up. See memberPath()'s and
// countPinInStmt()'s own comments, below, for the precise rule and its two
// known remaining limits (an unresolvable path shape, and a chain hop).

// The root Identifier AST NODE (not just its name — rootIdent() above
// already computes the name; this is its sibling for when the NODE itself
// is needed, to resolve the binding it names).
function rootIdentNode(node) {
  let n = node;
  for (;;) {
    if (n.type === "MemberExpression") n = n.object;
    else if (n.type === "CallExpression") n = n.callee;
    else if (n.type === "ChainExpression") n = n.expression;
    else if (n.type === "TSNonNullExpression") n = n.expression;
    else break;
  }
  return n.type === "Identifier" ? n : null;
}

// m23-gl — the full property-name path from the ROOT identifier down to
// `node`, ROOT FIRST: `res.landings` -> ["res", "landings"]; a bare
// identifier `x` -> ["x"]. This is the PROPERTY axis that root-identity
// alone (rootIdent/rootIdentNode, above) cannot see: two reads can share a
// root binding and still be different properties of it.
//
// Returns `null` when the chain contains a shape this conservative walk
// does not structurally model — a CallExpression in the middle (`foo().bar`,
// receiver came off a call, not a plain property read) or a computed member
// with a non-Literal key (`res[i]`). ⚠️ A null here is deliberately treated
// by countPinInStmt() as "cannot verify the property axis, fall back to the
// OLD root-only match" — NOT this file's usual fail-toward-flagging stance.
// Reason: tightening a shape this scanner cannot even describe risks a
// silent regression on some corpus shape never audited against it, for a
// combination (a call-derived receiver sharing a root with a candidate pin)
// with no known motivating site, at-risk or otherwise. See countPinInStmt()
// for where this is applied and derivationChain()'s own header for the
// SEPARATE, still-open gap on a chain-hop candidate — this function is not
// involved in that leg at all (see findCountPin()'s call site below).
function memberPath(node) {
  const parts = [];
  let n = node;
  for (;;) {
    if (n.type === "ChainExpression") { n = n.expression; continue; }
    if (n.type === "TSNonNullExpression") { n = n.expression; continue; }
    if (n.type === "Identifier") { parts.unshift(n.name); return parts; }
    if (n.type === "MemberExpression") {
      if (n.computed) {
        if (n.property.type !== "Literal") return null;
        parts.unshift(String(n.property.value));
      } else {
        if (n.property.type !== "Identifier") return null;
        parts.unshift(n.property.name);
      }
      n = n.object;
      continue;
    }
    return null; // CallExpression, ThisExpression, etc. — not modelled
  }
}

// Structural equality of two memberPath() results — plain array-of-strings compare.
function pathsEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

// Ancestor path from `root` (INCLUSIVE — root genuinely is an ancestor of
// anything strictly inside it) down to (EXCLUDING) `target`, found by a
// plain recursive descent over the AST's own shape. Deliberately NOT reused
// from acorn-walk's own ancestor visitors (`walk.fullAncestor`), which only
// enumerate the node TYPES they are told about via a base-visitor table —
// this instead walks every own-enumerable child, so it cannot silently miss
// a node shape the base visitor wasn't told about. `root` is normally a
// SINGLE STATEMENT — small, EXCEPT at the outermost climb level in
// findCountPin(), where `root` can be an entire top-level block (in
// `m23aj2-move-wire.mjs`, the whole `try { … }` body) — this is a census
// over ~75 files run periodically, not a hot path, and the corpus's gate
// files are hundreds of lines at most, so an occasional whole-block walk is
// not a cost worth optimising away.
function findAncestorPath(root, target) {
  let result = null;
  (function visit(node, path) {
    if (result || !node || typeof node !== "object" || typeof node.type !== "string") return;
    if (node === target) { result = path; return; }
    const nextPath = path.concat([node]);
    for (const key in node) {
      if (result) return;
      if (key === "loc" || key === "start" || key === "end" || key === "range") continue;
      const v = node[key];
      if (Array.isArray(v)) {
        for (const item of v) { if (result) return; visit(item, nextPath); }
      } else if (v && typeof v === "object" && typeof v.type === "string") {
        visit(v, nextPath);
      }
    }
  })(root, []);
  return result;
}

// Does `scopeNode` ITSELF (not some nested child scope) declare `name` as a
// block-scoped binding? Covers: `let`/`const`/function-decl/class-decl at
// the top level of a Block/Program/SwitchStatement (a `switch` body's cases
// share exactly ONE block scope, not one each — modelled here because two
// gates in this corpus use `switch`, even though neither currently needs
// it for a receiver this census tracks); a function's own parameters;
// a for-of/for-in/for(let…) loop's own declarator; a catch clause's own
// parameter. Returns the declaring node — used as the BINDING IDENTITY
// itself: two references share a binding iff they resolve to the identical
// node object — or null.
function declaresInScope(scopeNode, name) {
  if (scopeNode.type === "BlockStatement" || scopeNode.type === "Program") {
    for (const stmt of scopeNode.body) {
      if (stmt.type === "VariableDeclaration" && stmt.kind !== "var") {
        for (const d of stmt.declarations) {
          if (d.id.type === "Identifier" && d.id.name === name) return d;
        }
      }
      if (stmt.type === "FunctionDeclaration" && stmt.id?.name === name) return stmt;
      if (stmt.type === "ClassDeclaration" && stmt.id?.name === name) return stmt;
    }
    return null;
  }
  if (scopeNode.type === "SwitchStatement") {
    for (const c of scopeNode.cases) {
      for (const stmt of c.consequent) {
        if (stmt.type === "VariableDeclaration" && stmt.kind !== "var") {
          for (const d of stmt.declarations) {
            if (d.id.type === "Identifier" && d.id.name === name) return d;
          }
        }
        if (stmt.type === "FunctionDeclaration" && stmt.id?.name === name) return stmt;
        if (stmt.type === "ClassDeclaration" && stmt.id?.name === name) return stmt;
      }
    }
    return null;
  }
  if (/Function/.test(scopeNode.type)) {
    return scopeNode.params?.find((p) => p.type === "Identifier" && p.name === name) || null;
  }
  if (scopeNode.type === "ForOfStatement" || scopeNode.type === "ForInStatement") {
    const left = scopeNode.left;
    if (left?.type === "VariableDeclaration") {
      for (const d of left.declarations) if (d.id.type === "Identifier" && d.id.name === name) return d;
    }
    return null;
  }
  if (scopeNode.type === "ForStatement") {
    const init = scopeNode.init;
    if (init?.type === "VariableDeclaration" && init.kind !== "var") {
      for (const d of init.declarations) if (d.id.type === "Identifier" && d.id.name === name) return d;
    }
    return null;
  }
  if (scopeNode.type === "CatchClause") {
    if (scopeNode.param?.type === "Identifier" && scopeNode.param.name === name) return scopeNode.param;
    return null;
  }
  return null;
}

// `var` (and a `for (var …)` loop head) is FUNCTION-scoped, not
// block-scoped — it hoists to the nearest enclosing function (or Program,
// at the top level) regardless of how many bare `{ }`/if/for blocks sit
// between the declaration and that boundary. Searched with a plain
// recursive descent bounded to `fnOrProgram`'s own subtree, refusing to
// cross into any NESTED function — a `var` inside a nested function is that
// function's own hoisted binding, not this one's.
function collectVarDecl(fnOrProgram, name) {
  let found = null;
  (function visit(node, isRoot) {
    if (found || !node || typeof node !== "object" || typeof node.type !== "string") return;
    if (!isRoot && /Function/.test(node.type)) return;   // do not cross a nested function boundary
    if (node.type === "VariableDeclaration" && node.kind === "var") {
      for (const d of node.declarations) {
        if (d.id.type === "Identifier" && d.id.name === name) { found = d; return; }
      }
    }
    for (const key in node) {
      if (found) return;
      if (key === "loc" || key === "start" || key === "end" || key === "range") continue;
      const v = node[key];
      if (Array.isArray(v)) { for (const item of v) { if (found) return; visit(item, false); } }
      else if (v && typeof v === "object" && typeof v.type === "string") visit(v, false);
    }
  })(fnOrProgram, true);
  return found;
}

// Resolve `name` to its declaring node by walking `ancestorPath` (root
// first, immediate parent last — the shape both acorn-walk's own ancestors
// array and findAncestorPath() above produce) from INNERMOST scope outward,
// the way a JS engine's own scope chain does: nearest enclosing block wins
// for let/const, nearest enclosing function (or Program) wins for var/
// params. Returns { declNode, scopeNode }, or null if this scanner cannot
// place `name` in any scope on the path — a destructuring pattern, an
// import, a global, or some other shape it does not model. ⚠️ The caller
// MUST treat a null result as "cannot verify", never as "assume it
// clears" — this file's standing fail-toward-flagging rule, applied here.
function resolveBinding(name, ancestorPath) {
  for (let i = ancestorPath.length - 1; i >= 0; i--) {
    const scopeNode = ancestorPath[i];
    const isBlockLikeScope =
      scopeNode.type === "BlockStatement" || scopeNode.type === "Program" ||
      scopeNode.type === "SwitchStatement" || /Function/.test(scopeNode.type) ||
      scopeNode.type === "ForOfStatement" || scopeNode.type === "ForInStatement" ||
      scopeNode.type === "ForStatement" || scopeNode.type === "CatchClause";
    if (isBlockLikeScope) {
      const decl = declaresInScope(scopeNode, name);
      if (decl) return { declNode: decl, scopeNode };
    }
    const isVarScope = scopeNode.type === "Program" || /Function/.test(scopeNode.type);
    if (isVarScope) {
      const varDecl = collectVarDecl(scopeNode, name);
      if (varDecl) return { declNode: varDecl, scopeNode };
    }
  }
  return null;
}
// ─────────────────────────────────────────────────────────────────────────

// IDIOM B: a count pin on the same receiver. `s.length >= 5` clears it — a
// short run reddens THERE, so the `.every` below can no longer pass vacuously.
// Only `>=`/`>`/`===` against a NON-ZERO literal count as a pin: `s.length >= 0`
// is vacuous itself, and `x.length === 0` is an emptiness ASSERTION, not a pin.
//
// ⚠️ m23-ex — NAME MATCH ALONE IS NOT ENOUGH, see the scope-resolution block
// just above: a sibling block can declare its own same-named `const`
// (`m23aj2-move-wire.mjs:86` vs `:208`). `ancestorsPrefix` is the path from
// Program down to (and including) the body level currently being scanned in
// findCountPin(); `wantedDecl` is the SITE's own resolved binding for
// `recvRoot`, computed once by the caller. A candidate only counts as a pin
// if ITS `recvRoot` resolves to that exact same node.
//
// ⚠️ m23-gl — BINDING IDENTITY IS NOT THE PROPERTY AXIS EITHER. Same-binding
// (above) answers "same variable?"; `recvPath`, if given, answers "same
// PROPERTY of it?" — `res.clips.length === 2` and `res.landings.every(…)`
// both resolve `res` to one binding but describe two different properties
// of it, and the count pin says nothing about the property being iterated.
// `recvPath` is `memberPath(...)` of the SITE's own receiver, computed ONCE
// by the caller (findCountPin()) and threaded through unchanged; `null`
// means "do not apply this axis" (see findCountPin()'s call site: that is
// deliberately the case for a chain hop, where there is no single receiver
// node this leg is standing in for — see derivationChain()'s header).
//
// ⚠️ WHEN `recvPath` IS given (the receiver could itself be structurally
// described — including a BARE IDENTIFIER, `["landings"]`, which is why
// this is NOT gated on `recvPath.length > 1`: a bare-identifier receiver is
// not immune to this axis either — `landings.clips.length === 2` pins a
// DIFFERENT thing than `landings.every(…)` just as surely as the property
// case does, and gating on length would let it straight through), the
// candidate's own path (`len.object`, via `memberPath()`) must match it
// EXACTLY. If the candidate's path is itself NOT structurally describable
// (`res[i].length`, `foo().bar.length`), that is a REJECTION, not a
// fallback: `recvPath` is known here, so a candidate that cannot be shown
// to describe the SAME thing has not earned the clear — this file's own
// documented stance for a CLEARING rule specifically (m23-eu's comment,
// above prevReassignment(): "the opposite of this file's usual
// over-reporting-is-inspectable stance, which is about FLAGGING, not
// clearing"). The ONE remaining permissive branch is `recvPath === null`
// itself (the RECEIVER, not the candidate, is undescribable — nothing to
// compare against at all) — see memberPath()'s header for why that specific
// direction stays root-only.
function countPinInStmt(stmt, recvRoot, code, ancestorsPrefix, wantedDecl, recvPath) {
  let found = null;
  let propertyMismatch = false;   // m23-gl — at least one root+shape match rejected on the property axis
  walk.simple(stmt, {
    BinaryExpression(b) {
      if (found) return;
      if (!/^(>=|>|===|==)$/.test(b.operator)) return;
      const [len, lit] = b.left.type === "MemberExpression" ? [b.left, b.right] : [b.right, b.left];
      if (!len || len.type !== "MemberExpression" || len.property?.name !== "length") return;
      if (lit?.type !== "Literal" || typeof lit.value !== "number" || lit.value <= 0) return;
      const identNode = rootIdentNode(len.object);
      if (!identNode || identNode.name !== recvRoot) return;
      if (recvPath) {
        const pinPath = memberPath(len.object);
        if (!pinPath || !pathsEqual(pinPath, recvPath)) { propertyMismatch = true; return; }   // m23-gl
      }
      const innerPath = findAncestorPath(stmt, identNode);
      const candBinding = innerPath ? resolveBinding(recvRoot, ancestorsPrefix.concat(innerPath)) : null;
      if (!candBinding || candBinding.declNode !== wantedDecl) return;
      found = txt(code, b).slice(0, 60);
    },
  });
  return { found, propertyMismatch };
}

// ⑦ (m23-ee-2c-2b) — a pin AFTER the site is exactly as visible as one
// before it: `check()`/`ck()` push a row and CONTINUE — no throw, no
// short-circuit — so a gate's verdict is its WHOLE fail-list, not the first
// failure in source order. `m23e-empty-lane-create.mjs:212` is the motivating
// site, "pinned" (per the item) by `:215`. DELIBERATELY ADDITIVE, not a
// rewrite of the existing backward scan below — the backward scan is
// unchanged from before this item, byte-for-byte, so nothing that already
// cleared can un-clear.
//
// ⚠️ THE FORWARD DIRECTION'S OWN TRAP, CAUGHT BY TESTING IT (NOT ASSUMED): a
// FIRST DRAFT scanned the whole block both ways and matched `recvRoot` by
// NAME only. `recvRoot` can be a `let` REASSIGNED many times in the same
// block (m23m3c-stems-dialog.mjs reassigns `st` via `st = await cmd(...)`
// five separate times) — the draft found `st.tracks.length === 4`, a
// DIFFERENT snapshot's assertion three reassignments later, and used it to
// "clear" a receiver (`st.plannedFiles`) that snapshot never held. That is a
// name collision across reassignment epochs, not a pin, and it is exactly the
// over-clearing direction that matters for a CLEARING rule (the opposite of
// this file's usual "over-reporting is inspectable" stance, which is about
// FLAGGING, not clearing). nextReassignment() below bounds the forward scan
// to stop at the next place `recvRoot` is reassigned — the span where the
// name still provably holds the value the site actually reads. A `const`
// (never reassigned) has no such boundary and keeps the full forward reach.
function nextReassignment(body, recvRoot, site) {
  let hi = Infinity;
  for (const stmt of body) {
    if (stmt.start < site.end) continue;
    const isReassign =
      (stmt.type === "VariableDeclaration" &&
        stmt.declarations.some((d) => d.id.type === "Identifier" && d.id.name === recvRoot)) ||
      (stmt.type === "ExpressionStatement" && stmt.expression?.type === "AssignmentExpression" &&
        stmt.expression.operator === "=" && stmt.expression.left.type === "Identifier" &&
        stmt.expression.left.name === recvRoot);
    if (isReassign && stmt.start < hi) hi = stmt.start;
  }
  return hi;
}

// ⚠️ m23-eu — mirror of nextReassignment() (⑦, above), for the BACKWARD
// scan. The forward scan is bounded by the NEXT reassignment of `recvRoot`;
// the backward scan had NO such bound and accepted the FIRST pin found
// walking the body top-down, however stale a snapshot it described — the
// same cross-reassignment-epoch hazard ⑦'s own comment documents catching
// on the FORWARD side, just uncaught here. Confirmed instance:
// m23ek-clipboard.mjs:293/295 — `e` is reassigned via `e = await cb(...)`
// TEN times between a pin at :161 (`e.clips.filter(...).length === 1`) and
// the site, which reads the `e` assigned at :291; the old backward scan
// still "cleared" it against the stale :161 snapshot. prevReassignment()
// returns the START of the LAST reassignment of `recvRoot` strictly before
// the site; the backward scan below then only accepts a pin in a statement
// strictly AFTER that point. A receiver never reassigned in this body
// (e.g. a `const`, such as `pastedNotes` at m23ek-clipboard.mjs:349) has no
// such boundary, returns -Infinity, and keeps its full backward reach —
// unchanged, exactly as nextReassignment() treats that case going forward
// (+Infinity, full forward reach).
//
// ⚠️ DELIBERATELY NOT a byte-for-byte mirror of nextReassignment() in one
// respect: nextReassignment() also treats a `VariableDeclaration` matching
// `recvRoot` as a reassignment; prevReassignment() only matches a plain `=`
// AssignmentExpression. `e` in the m23ek case is never re-declared, only
// ever plain-assigned, so this asymmetry costs that confirmed fix nothing.
//
// ⚠️⚠️ CORRECTED AT m23-ex — this comment PREVIOUSLY recorded
// `m23aj2-move-wire.mjs:208` staying cleared as a REQUIREMENT ("the item's
// own control set holds this specific instance OUT of scope … is required
// to STAY cleared"). That requirement was itself the bug: the control set it
// cited was DERIVED FROM this scanner's own (buggy) output, so it silently
// encoded this exact over-clear as correct — `:86`'s `landings` and `:208`'s
// `landings` are TWO SEPARATE `const` bindings in non-overlapping SIBLING
// bare `{ }` blocks (:75-91 vs :195-212), unrelated variables that share a
// name, not the same value at two points in time. `:208` is now, correctly,
// NOT cleared. This did NOT need extending prevReassignment() (adding the
// VariableDeclaration leg here would not even have reached the defect — the
// redeclaration at `:85` sits INSIDE a sibling bare-block statement, never a
// TOP-LEVEL statement of the body prevReassignment() scans, so it would
// never have matched `isReassign` regardless). It needed exactly what this
// comment's own last sentence, before this correction, already predicted:
// real lexical scope resolution — see resolveBinding()/countPinInStmt(),
// above prevReassignment() in this file — which findCountPin() now applies
// as an INDEPENDENT check, layered on top of (not replacing) the
// reassignment-epoch bound below: binding identity answers "is this the
// same variable"; the epoch bound answers "is this still the same VALUE of
// that variable". Both must hold; neither subsumes the other.
//
// ⚠️ KNOWN LIMIT, inherited from nextReassignment(): this only walks the
// TOP-LEVEL statements of `body`, so a reassignment nested inside an
// `if`/loop is invisible to it. That makes the bound too PERMISSIVE for
// that shape, not wrong — the over-clear this item fixes simply persists
// for a nested reassignment, which is the conservative-census trade-off
// this file already makes elsewhere (see FIXED_BOUND_DEPTH_CAP and
// localHelperCall()'s header for the same shape of trade). Not solved here;
// scope resolution is out of scope for this census, per the item brief.
function prevReassignment(body, recvRoot, site) {
  let lo = -Infinity;
  for (const stmt of body) {
    if (stmt.start >= site.start) continue;
    const isReassign =
      stmt.type === "ExpressionStatement" && stmt.expression?.type === "AssignmentExpression" &&
      stmt.expression.operator === "=" && stmt.expression.left.type === "Identifier" &&
      stmt.expression.left.name === recvRoot;
    if (isReassign && stmt.start > lo) lo = stmt.start;
  }
  return lo;
}

// Returns { found: string|null, unresolved: boolean, propertyMismatch: boolean }.
// `unresolved: true` means the SITE's own `recvRoot` could not be placed in
// any scope on its ancestor path (m23-ex, resolveBinding() above) — a
// scanner limitation, not a "no pin exists" verdict; the caller surfaces
// this in the row's own `pinScope` field rather than letting it collapse
// into an identical-looking `pin: null`. See this function's own header
// comment, further up, for why.
//
// `recvPath` (m23-gl) is `memberPath()` of the receiver this particular call
// is standing in for, or `null` to skip the property-axis check entirely —
// see the call site (the `chain` loop, far below) for exactly when each is
// passed: `recvPath` is only ever given on the FIRST chain entry (the
// site's own, un-derived receiver); a chain hop always passes `null`,
// because derivationChain() only ever yields a bare root NAME for a hop,
// with no property expression left to compare against (see its own header).
//
// `propertyMismatch` (m23-gl) — mirrors `unresolved`'s own reasoning, one
// axis over: true when at least one candidate shared `recvRoot` and the
// count-pin SHAPE (a `.length` comparison against a positive literal, same
// binding-eligible root) but was rejected because it could not be shown to
// describe the SAME property as `recvPath` — see countPinInStmt()'s own
// header. Surfaced in `pinScope` (below, at the call site) so a rejection
// on THIS axis doesn't look identical to "no pin candidate was ever found",
// the exact collapse `unresolved` exists to prevent for the binding axis.
function findCountPin(ancestors, recvRoot, site, code, recvPath) {
  // m23-ex — resolve the SITE's own binding for `recvRoot` ONCE, before
  // scanning anything. Every candidate pin found below must resolve to this
  // SAME declaring node (by identity) to count — see countPinInStmt()'s own
  // header, above. FAIL TOWARD FLAGGING: if the site's own binding cannot be
  // resolved, there is nothing to verify a candidate against, so this
  // returns immediately rather than falling back to the old name-only match.
  const siteBinding = resolveBinding(recvRoot, ancestors);
  if (!siteBinding) return { found: null, unresolved: true, propertyMismatch: false };
  const wantedDecl = siteBinding.declNode;
  let anyPropertyMismatch = false;   // m23-gl — accumulated across every statement/level tried below

  // ⚠️ m23-eu — `knownLo` is a RUNNING FLOOR carried ACROSS ancestor levels,
  // not recomputed fresh at each one. Needed because findCountPin already
  // climbs multiple enclosing bodies (try-block, then Program, etc. — this
  // climb predates this item and is unrelated to it) when an inner level
  // yields no pin. A first version called prevReassignment() fresh per
  // level and it UNDID ITS OWN FIX ONE LEVEL OUT: at the inner level (the
  // try-block body containing both the :291 reassignment and the :293
  // site), prevReassignment correctly bounded the scan and (correctly)
  // found nothing — but findCountPin then climbed to the OUTER level
  // (Program), where the ENTIRE try/catch is a single opaque top-level
  // statement. From THAT body's perspective the :291 reassignment is
  // invisible (nested inside the try, not a top-level statement of
  // Program — the exact documented top-level-only limit), so a
  // freshly-computed prevReassignment there returned -Infinity, and the
  // unbounded fallback re-walked the WHOLE try statement and re-found the
  // same stale :161 pin — the fix passing at level 1 and silently
  // reverting at level 2. Byte offsets are absolute regardless of AST
  // nesting, so the bound found at an inner level remains valid at any
  // outer level: `knownLo` is threaded through and only ever raised
  // (Math.max), never reset, closing that reversion without touching the
  // FORWARD scan or the climbing behaviour itself.
  let knownLo = -Infinity;
  for (let i = ancestors.length - 1; i >= 0; i--) {
    const a = ancestors[i];
    const body = a.type === "BlockStatement" || a.type === "Program" ? a.body : null;
    if (!body) continue;
    const ancestorsPrefix = ancestors.slice(0, i + 1);   // Program … a, inclusive — m23-ex

    // BACKWARD — bounded by prevReassignment() (m23-eu, above): only a
    // statement strictly AFTER the last reassignment of `recvRoot` before
    // the site can pin it — anything at or before that reassignment
    // describes a snapshot the site no longer reads.
    const levelLo = prevReassignment(body, recvRoot, site);
    if (levelLo > knownLo) knownLo = levelLo;
    for (const stmt of body) {
      if (stmt.start >= site.start) break;
      if (stmt.start <= knownLo) continue;   // stale — superseded by a later reassignment
      const r = countPinInStmt(stmt, recvRoot, code, ancestorsPrefix, wantedDecl, recvPath);
      if (r.propertyMismatch) anyPropertyMismatch = true;
      if (r.found) return { found: r.found, unresolved: false, propertyMismatch: false };
    }

    // FORWARD (⑦) — any statement strictly after the site, up to (not
    // including) the next reassignment of `recvRoot`. Skips the site's own
    // containing statement implicitly (its start is not > site.start... it
    // IS > site.start if it's a later stmt; the site's own stmt is excluded
    // by requiring stmt.start > site.end below, not just > site.start, since
    // a multi-line statement's start can be <= site.start).
    const hi = nextReassignment(body, recvRoot, site);
    for (const stmt of body) {
      if (stmt.start <= site.end) continue;   // the site's own statement, or anything not strictly after it
      if (stmt.start >= hi) break;            // past this binding's reassignment epoch
      const r = countPinInStmt(stmt, recvRoot, code, ancestorsPrefix, wantedDecl, recvPath);
      if (r.propertyMismatch) anyPropertyMismatch = true;
      if (r.found) return { found: r.found, unresolved: false, propertyMismatch: false };
    }
  }
  return { found: null, unresolved: false, propertyMismatch: anyPropertyMismatch };
}

// Is `name` an accumulator whose fill count is fixed at authoring time?
//
// ⚠️ THIS RULE EXISTS BECAUSE THE CENSUS CONTRADICTED A RECORDED VERDICT.
// m23-bj inspected `m23s` and recorded it CLEAN; my first census flagged 8 sites
// in it. Reading the code settled it in m23-bj's favour:
//     const masterHeights = [], reserveHeights = [];
//     for (let n = 1; n <= 4; n++) { … masterHeights.push(…) … }
// a LITERAL-bound loop with an UNCONDITIONAL push — always exactly 4 elements,
// so `.every()` over it can never be vacuous. Without this rule the census would
// have "found" 8 defects in a gate that has none, and a census that cries wolf
// on a known-clean gate is one nobody will action.
//
// Deliberately conservative: any push under an `if`, or in a loop whose bounds
// are not both literal, stays a candidate. Over-reporting is inspectable;
// under-reporting is the failure mode that hides real defects.
// ⑤ (m23-ee-2c-2b) — resolve a numeric `for` loop's BOUND when it is a
// module-scope `const` IDENTIFIER, not just a literal. m23am-refusal-anchor.mjs:
//     const N_A = 8;                              // :97, module scope
//     for (let i = 0; i < N_A; i++) { … aIDs.push(…) … }   // :179-181
// The existing fixed-bound rule demanded a LITERAL test bound, so `i < N_A`
// unconditionally bailed even though `N_A` is exactly as fixed as `i < 8`
// would be. Deliberately MODULE-SCOPE ONLY (`ast.body`, not a nested block) —
// a `const` inside a function could shadow the module-level one, and this
// stays a conservative census, not a scope-resolving one.
function moduleConstNumber(ast, name) {
  for (const stmt of ast.body) {
    if (stmt.type !== "VariableDeclaration" || stmt.kind !== "const") continue;
    for (const d of stmt.declarations) {
      if (d.id.type === "Identifier" && d.id.name === name &&
          d.init?.type === "Literal" && typeof d.init.value === "number") {
        return d.init.value;
      }
    }
  }
  return null;
}

function fixedFillCount(ast, name, code, depth = 0) {
  if (depth > FIXED_BOUND_DEPTH_CAP) return null;
  let pushes = 0, safe = 0, detail = null;
  walk.fullAncestor(ast, (n, _s, anc) => {
    if (n.type !== "CallExpression") return;
    const c = n.callee;
    if (c.type !== "MemberExpression" || c.property?.name !== "push") return;
    if (rootIdent(c.object) !== name) return;
    pushes++;
    // Walk out to the nearest loop, refusing if a conditional intervenes.
    for (let i = anc.length - 2; i >= 0; i--) {
      const a = anc[i];
      if (a.type === "IfStatement" || a.type === "SwitchCase" || a.type === "LogicalExpression") return;
      if (a.type === "ForStatement") {
        const init = a.init?.declarations?.[0]?.init;
        const test = a.test;
        const okInit = init && init.type === "Literal" && typeof init.value === "number";
        // ⑤: the bound may be a LITERAL (as before) or a module-scope `const`
        // identifier that resolves to one (moduleConstNumber, just above).
        let boundValue = null;
        if (test && test.type === "BinaryExpression" && /^(<=|<)$/.test(test.operator)) {
          if (test.right.type === "Literal" && typeof test.right.value === "number") {
            boundValue = test.right.value;
          } else if (test.right.type === "Identifier") {
            boundValue = moduleConstNumber(ast, test.right.name);
          }
        }
        const okTest = boundValue !== null;
        if (okInit && okTest) {
          const iters = test.operator === "<=" ? boundValue - init.value + 1
                                               : boundValue - init.value;
          if (iters > 0) { safe++; detail = `fixed-bound loop, ${iters} iteration(s): ${txt(code, a.test)}`; }
        }
        return;
      }
      // ⚠️ BLIND SPOT 1/2 (m23-ee-2c) — for-of over a NON-EMPTY ARRAY LITERAL,
      // or over an identifier that ITSELF resolves (one hop, depth-capped) to
      // a fixed-bound accumulator. m23g1-arrange-multiselect.mjs:203-206:
      //     const tracks = [];
      //     for (const n of ["G1a", "G1b", "G1c"]) tracks.push(...);
      // an unconditional push inside a for-of over a non-empty array literal
      // is exactly N elements, always — same reasoning as the numeric
      // ForStatement branch above, just a different loop shape (that branch
      // used to unconditionally bail on ANY for-of, which is what made this a
      // blind spot). And m23g1:220-223:
      //     const clips = [];
      //     for (const t of tracks) clips.push(...);
      // `tracks` is ITSELF a for-of-filled accumulator over the 3-element
      // literal above, so `clips.length === tracks.length === 3` always —
      // resolved by recursing into resolvedFixedBound() one level deeper,
      // capped by FIXED_BOUND_DEPTH_CAP so this can never walk an unbounded
      // alias chain (this is a census, not a dataflow analysis — see the
      // blind-spot-4 note on localHelperCall() for the line this is drawn at).
      if (a.type === "ForOfStatement") {
        const src = a.right;
        let desc = null;
        if (src.type === "ArrayExpression" && src.elements.length > 0) {
          desc = `a ${src.elements.length}-element array literal`;
        } else if (src.type === "Identifier") {
          desc = resolvedFixedBound(ast, src.name, code, depth + 1);
        }
        if (desc) { safe++; detail = `for-of over ${desc}`; }
        return;
      }
      if (a.type === "ForInStatement" || a.type === "WhileStatement") return;
      if (/Function/.test(a.type)) return;
    }
  });
  return pushes > 0 && safe === pushes ? detail : null;
}

// Depth cap shared by resolvedFixedBound() and fixedFillCount()'s for-of
// branch above: how many hops through an identifier alias / "accumulator of
// an accumulator" this scanner will follow before giving up. Deliberately
// small — this stays a CONSERVATIVE census, not a general dataflow analysis
// (interprocedural resolution — blind spot 4 — is explicitly out of scope for
// exactly this reason). m23g1 needs exactly ONE hop (`clips`, filled by a
// for-of over `tracks`, itself filled by a for-of over a literal) and no
// known gate in this corpus needs more; "2 is enough" per the item brief.
const FIXED_BOUND_DEPTH_CAP = 2;

// Does identifier `name` resolve, at authoring time, to a fixed-length array?
// Three cases, all conservative (return null — i.e. "don't know" — the
// instant any step doesn't match cleanly):
//   (a) a non-empty array literal declarator: `const X = [1, 2, 3]`.
//   (b) an empty-literal accumulator whose fill fixedFillCount can prove
//       fixed-bound (recurses ONE level deeper, via the shared depth cap).
//   (c) a length-preserving chain (`X.map(...)`) over a base that itself
//       resolves the same way (blind spot 2's map-chain half — see
//       lengthPreservingChainBase() and its call site below).
// Returns a human-readable description, or null.
function resolvedFixedBound(ast, name, code, depth) {
  if (depth > FIXED_BOUND_DEPTH_CAP) return null;
  let decl = null;
  walk.simple(ast, {
    VariableDeclarator(d) {
      if (d.id.type === "Identifier" && d.id.name === name && !decl) decl = d;
    },
  });
  if (!decl?.init) return null;
  if (decl.init.type === "ArrayExpression" && decl.init.elements.length > 0) {
    return `a ${decl.init.elements.length}-element array literal`;
  }
  if (decl.init.type === "ArrayExpression" && decl.init.elements.length === 0) {
    const fixed = fixedFillCount(ast, name, code, depth + 1);
    return fixed ? `an accumulator filled by a ${fixed}` : null;
  }
  const chainBase = lengthPreservingChainBase(decl.init);
  if (chainBase) {
    const baseFixed = resolvedFixedBound(ast, chainBase.base, code, depth + 1);
    return baseFixed ? `${chainBase.ops.join("/")} over \`${chainBase.base}\`, itself ${baseFixed}` : null;
  }
  return null;
}

// Unwrap a length-preserving call chain (`X.map(...)`) down to its base
// identifier, for when the BASE (not the receiver itself) needs resolving —
// this is the sibling of the inline-literal-chain unwind already done inside
// classifyInit()'s CallExpression case, just working off a var reference
// instead of an inline array literal.
function lengthPreservingChainBase(init) {
  if (init.type !== "CallExpression") return null;
  let n = init, ops = [];
  while (n.type === "CallExpression" && n.callee.type === "MemberExpression") {
    ops.push(n.callee.property.name);
    n = n.callee.object;
  }
  if (n.type === "Identifier" && ops.length > 0 && ops.every((o) => LEN_PRESERVING.has(o))) {
    return { base: n.name, ops };
  }
  return null;
}

// ⚠️ BLIND SPOT 4 (m23-ee-2c) — INTERPROCEDURAL. Explicitly OUT OF SCOPE: "A
// general interprocedural analysis is out of scope and will not fit." But a
// receiver whose initialiser is a call (optionally awaited) to a function
// DECLARED IN THIS FILE is at least DISTINGUISHABLE from a genuine unknown —
// it is "go read one function", not "trace an external API this tool has no
// hope of following". m23ak-note-selection-drop.mjs:191-193 + :300 + :550:
//     async function starts(ids) { const all = await clipsByID(); return ids.map(...); }
//     let after = await starts([a0, a1, a2]);   // length === 3, always
//     const afterL5 = await starts(L5.clips);   // length === L5.clips.length
// Tagged `HELPER-RETURN` and left `cleared: false` — the tool genuinely does
// not resolve the helper body, so this is NOT a clearing rule — but counted
// SEPARATELY via the top-level `notClearedByProvenance` field so a consumer
// can see how much of `notCleared` is merely "go read this one function"
// versus a real unknown.
function localHelperCall(init, ast) {
  const call = init.type === "AwaitExpression" ? init.argument : init;
  if (!call || call.type !== "CallExpression" || call.callee.type !== "Identifier") return null;
  const name = call.callee.name;
  let isLocal = false;
  walk.simple(ast, {
    FunctionDeclaration(n) { if (n.id?.name === name) isLocal = true; },
    VariableDeclarator(n) {
      if (n.id.type === "Identifier" && n.id.name === name &&
          (n.init?.type === "ArrowFunctionExpression" || n.init?.type === "FunctionExpression")) {
        isLocal = true;
      }
    },
  });
  return isLocal ? { name, awaited: init.type === "AwaitExpression" } : null;
}

// ⑨ (m23-ee-2c-2b) — is `name` a parameter of the NEAREST enclosing function?
// The mirror-image question to localHelperCall() above: that one asks "does
// this value come FROM a call this tool can name", this one asks "does this
// value come IN as a parameter this tool cannot trace to a caller". Only the
// nearest enclosing function counts as "that helper's own parameter" — a
// receiver two functions further out is a different, unasked question.
// Plain `Identifier` params only (no destructuring/rest) — the corpus's
// motivating sites are all plain, and a wrong guess on a destructured param
// is worse than reporting nothing.
function enclosingParamOwner(anc, name) {
  for (let k = anc.length - 1; k >= 0; k--) {
    const fn = anc[k];
    if (!/Function/.test(fn.type)) continue;
    if (!fn.params.some((p) => p.type === "Identifier" && p.name === name)) return null;
    if (fn.id?.name) return fn.id.name;
    const parent = anc[k - 1];
    if (parent?.type === "VariableDeclarator" && parent.init === fn && parent.id.type === "Identifier") {
      return parent.id.name;
    }
    return "<anonymous fn>";
  }
  return null;
}

// ⚠️ BLIND SPOT 3 (m23-ee-2c) — idiom D: a preceding, ASSERTED `.some()` leg
// on the SAME predicate as a `.filter(...)` receiver.
// m23al-editor-surface.mjs:499-518:
//     const sawTrue  = iRows.some((r) => r.focused === true);
//     check("I0 …", sawTrue && sawFalse, …);                    <- asserted here
//     const onTrue = iRows.filter((r) => r.focused === true);
//     check("I1 …", onTrue.every(...) && …, …);                 <- onTrue.every() is the site
// If `iRows.some(P)` is true — and it IS asserted, so a short/empty run
// reddens THAT leg first — then `iRows.filter(P)` cannot be empty. Kept
// deliberately narrow, all three conditions required together:
//   (a) the receiver's initialiser is literally `SRC.filter(PRED)`;
//   (b) a PRECEDING `SRC.some(PRED2)` exists (same root identifier) where
//       PRED2's SOURCE TEXT is byte-identical to PRED's — not "similar": a
//       predicate that drifts even slightly is no longer the same claim;
//   (c) that `.some()` result is actually READ by a check(/ck(...) call
//       before the site — either inline or via an identifier it was assigned
//       to. A `.some()` that is computed and never asserted pins nothing (it
//       could be dead code, or gated behind a path that never reddens).
function findSomeLegPin(ast, recvDecl, code, site) {
  if (!recvDecl?.init || recvDecl.init.type !== "CallExpression") return null;
  const filterCall = recvDecl.init;
  if (filterCall.callee.type !== "MemberExpression" || filterCall.callee.property?.name !== "filter") return null;
  const srcRoot = rootIdent(filterCall.callee.object);
  if (!srcRoot || !filterCall.arguments[0]) return null;
  const predText = txt(code, filterCall.arguments[0]);

  let someCall = null;
  walk.simple(ast, {
    CallExpression(n) {
      if (someCall || n.start >= site.start) return;
      if (n.callee.type !== "MemberExpression" || n.callee.property?.name !== "some") return;
      if (rootIdent(n.callee.object) !== srcRoot) return;
      if (!n.arguments[0] || txt(code, n.arguments[0]) !== predText) return;
      someCall = n;
    },
  });
  if (!someCall) return null;

  // (c), inline: `check(…, x.some(P), …)` / `ck(…, x.some(P), …)`.
  let assertedDirectly = false;
  walk.fullAncestor(ast, (n, _s, anc) => {
    if (n !== someCall || assertedDirectly) return;
    for (const a of anc) {
      if (a.type === "CallExpression" && a.callee.type === "Identifier" && /^(check|ck)$/.test(a.callee.name)) {
        assertedDirectly = true;
        break;
      }
    }
  });
  if (assertedDirectly) return txt(code, someCall).slice(0, 60);

  // (c), via an alias: `const sawTrue = x.some(P); check(…, sawTrue && …, …);`.
  // ⚠️ `ancestors` INCLUDES the node itself as its LAST element (confirmed by
  // direct test — every other ancestor-walk in this file already knows this,
  // e.g. the for-of resolution above uses `anc2[anc2.length - 2]`; this one
  // originally used `anc[anc.length - 1]`, which is `someCall` itself, so the
  // VariableDeclarator parent check never matched and this idiom silently
  // never fired for the alias path. Caught by the m23al control site staying
  // uncleared when the item brief said it should clear.
  let assignedName = null;
  walk.fullAncestor(ast, (n, _s, anc) => {
    if (n !== someCall || assignedName) return;
    const parent = anc[anc.length - 2];
    if (parent?.type === "VariableDeclarator" && parent.init === n && parent.id.type === "Identifier") {
      assignedName = parent.id.name;
    }
  });
  if (!assignedName) return null;
  let assertedViaAlias = false;
  walk.simple(ast, {
    CallExpression(n) {
      if (assertedViaAlias || n.start >= site.start) return;
      if (n.callee.type !== "Identifier" || !/^(check|ck)$/.test(n.callee.name)) return;
      for (const arg of n.arguments) {
        walk.simple(arg, { Identifier(id) { if (id.name === assignedName) assertedViaAlias = true; } });
      }
    },
  });
  return assertedViaAlias ? `\`${assignedName}\` (= ${txt(code, someCall).slice(0, 40)}), asserted before the site` : null;
}

// ⭐ (m23-fb) — blind spot ⑩: DETAIL-ARG. `check(name, condition, detail)`
// takes its verdict from argument 2 (condition, 0-based index 1); argument 3
// (detail, index 2) is only interpolated into the diagnostic STRING printed
// on failure — a vacuous `.every()`/`.some()`/`filter().length==0` site whose
// ONLY reachable role is inside that detail argument prints `true` instead of
// something more useful, but it CANNOT flip a failing gate to pass. That is a
// false positive BY CONSTRUCTION, needing no dataflow at all: the site's
// ARGUMENT INDEX within the enclosing call decides it, on its own.
//
// ⚠️ SCOPED STRICTLY BY ARGUMENT POSITION, NOT BY "is it inside a template
// literal". A condition argument can legitimately hold one — m23ek-clipboard
// .mjs:300 (`e.clips.every(...)` inside the `&&` chain that IS argument 1) is
// the control: it MUST stay cleared, never relabelled here. ⚠️⚠️ CORRECTED
// AT m23-ex — this previously said it clears "via the count-pin idiom
// (findCountPin, far above)"; MEASURED FALSE. `:300`'s own row reads
// `clearedBy: "inline .length conjunct", pin: null` — it clears via IDIOM A
// (findLengthGuard, the SAME-EXPRESSION `&&` conjunct `e.result === true &&
// e.clips.length === clipsBeforeCut - 1`), not idiom B at all. The
// REQUIREMENT (stays cleared) was correct; the stated MECHANISM was not —
// anyone reasoning from the old wording would mispredict that a
// findCountPin change could affect `:300`. It cannot: `:300` never reaches
// findCountPin, since `guard` (idiom A) is found first and idiom B is only
// tried `if (!guard)`. A detail argument can equally legitimately be a bare
// expression with no template literal at all — this function never looks at
// the argument's shape, only its POSITION.
//
// Climbs `anc` from the site outward exactly like `encl` (below) does —
// same function-boundary break — looking for the nearest CallExpression
// named `check`/`ck` (the only two helpers the item names; the corpus's
// other helpers — t/checks/expect/ok/leg — are out of scope for this rule).
// Once found, the argument index is decided by RANGE CONTAINMENT against
// that call's own `arguments` array: which argument's [start,end) span
// contains the site.
function detailArgCall(anc, node) {
  for (let i = anc.length - 1; i >= 0; i--) {
    const a = anc[i];
    if (a.type === "CallExpression" && a.callee.type === "Identifier" && /^(check|ck)$/.test(a.callee.name)) {
      const index = a.arguments.findIndex((arg) => arg.start <= node.start && node.end <= arg.end);
      return { callee: a.callee.name, index };
    }
    if (/Function/.test(a.type)) break;
  }
  return null;
}

// ⚠️ A GUARD CAN SIT ON THE **SOURCE** COLLECTION, NOT THE DERIVED ONE.
// Fourth thing the control set caught. m23s:236-239 reads:
//     const ints  = busSeen.map(slotsFor);
//     const steps = [...busSeen].sort(…).slice(1).map(…);
//     ck("…", busSeen.length >= 2 && ints.every(…) && steps.every(…));
// The guard names `busSeen`; the receivers are `ints`/`steps`. Both derive from
// `busSeen` by length-monotone ops, so `busSeen.length >= 2` really does bound
// them — the gate is correct and a scanner that only matches the receiver's OWN
// name calls it a defect. Resolve each receiver back through its derivation chain
// and accept a guard on ANY ancestor.
// ⚠️ m23-gl — a chain hop is a bare NAME (`base = rootIdent(n)`, below), never
// a property path: `const restored = res.landings.map(fn)` pushes `"res"`
// onto the chain, discarding `.landings` entirely. That is a SEPARATE,
// still-open instance of the property-axis gap countPinInStmt() otherwise
// closes (m23-gl) — a pin on `res.someOtherProp.length` would still "clear"
// `restored.every(…)` via this hop, because nothing downstream of this
// function retains what property of `res` `restored` was actually derived
// from. Deliberately left open: fixing it would mean this function returning
// a property path per hop, not just a name, which changes what every caller
// of `chain` (the `nm` loop, far below) receives — a larger, riskier change
// than this item's own scope (its filed shape has a single, un-hopped
// receiver), with no known motivating site in this corpus for the hop
// version either. If one is ever found, start here.
function derivationChain(ast, name, code) {
  const MONOTONE = new Set(["map", "sort", "slice", "reverse", "concat", "flat"]);
  const chain = [name];
  for (let hop = 0; hop < 4; hop++) {
    const cur = chain[chain.length - 1];
    let decl = null;
    walk.simple(ast, {
      VariableDeclarator(d) {
        if (d.id.type === "Identifier" && d.id.name === cur && !decl) decl = d;
      },
    });
    if (!decl?.init) break;
    let n = decl.init, ops = [];
    // Unwrap `[...X]` spread wrappers, which preserve length exactly.
    while (n.type === "ArrayExpression" && n.elements.length === 1 && n.elements[0]?.type === "SpreadElement") {
      n = n.elements[0].argument;
    }
    while (n.type === "CallExpression" && n.callee.type === "MemberExpression") {
      ops.push(n.callee.property.name);
      n = n.callee.object;
      while (n.type === "ArrayExpression" && n.elements.length === 1 && n.elements[0]?.type === "SpreadElement") {
        n = n.elements[0].argument;
      }
    }
    if (!ops.length || !ops.every((o) => MONOTONE.has(o))) break;
    const base = rootIdent(n);
    if (!base || chain.includes(base)) break;
    chain.push(base);
  }
  return chain;
}

// ⑥ (m23-ee-2c-2b) — a pin expressed as EQUALITY ON A DERIVED JOIN. A
// `.join()` (zero arguments — the default `","` separator, matching the
// corpus's one motivating shape) over a `.map(fn)` chain off the SAME
// receiver, compared for exact string equality against a NON-EMPTY literal,
// constrains the length exactly — satisfiable only by however many elements
// the joined string implies. m23v-empty-lane-hint.mjs:360-361 (E4, PRECEDING
// E5's `.every()` at :363):
//     hintsOf(e).map((h) => h.laneIndex).join() === "0,3"
// Deliberately narrow to a zero-arg `.join()`: a custom separator reopens the
// "is '' really zero elements" edge case (a lone empty-string element joined
// with a non-empty separator can itself produce "", so RHS === "" would no
// longer cleanly mean zero elements) — out of scope, no motivating site needs it.
// Requires the equality be itself ASSERTED inside a check(/ck( call, same as
// idiom D — an unasserted comparison pins nothing.
function findJoinPin(ancestors, recvNode, site, code) {
  const recvText = txt(code, recvNode);
  for (let i = ancestors.length - 1; i >= 0; i--) {
    const a = ancestors[i];
    const body = a.type === "BlockStatement" || a.type === "Program" ? a.body : null;
    if (!body) continue;
    for (const stmt of body) {
      if (stmt.start >= site.start) break;   // preceding-only, per the item's own motivating shape
      let found = null;
      walk.fullAncestor(stmt, (n, _s, anc2) => {
        if (found || n.type !== "BinaryExpression" || !/^(===|==)$/.test(n.operator)) return;
        const [joinExpr, lit] = n.left.type === "CallExpression" ? [n.left, n.right] : [n.right, n.left];
        if (!joinExpr || joinExpr.type !== "CallExpression") return;
        if (joinExpr.callee.type !== "MemberExpression" || joinExpr.callee.property?.name !== "join") return;
        if (joinExpr.arguments.length !== 0) return;
        if (lit?.type !== "Literal" || typeof lit.value !== "string" || lit.value === "") return;
        let base = joinExpr.callee.object;
        if (base.type === "CallExpression" && base.callee.type === "MemberExpression" &&
            base.callee.property?.name === "map") {
          base = base.callee.object;
        }
        if (txt(code, base) !== recvText) return;
        const asserted = anc2.some((a2) => a2.type === "CallExpression" &&
          a2.callee.type === "Identifier" && /^(check|ck)$/.test(a2.callee.name));
        if (!asserted) return;
        const elements = lit.value.split(",").length;
        found = `${txt(code, n).slice(0, 70)} (implies ${elements} element(s))`;
      });
      if (found) return found;
    }
  }
  return null;
}

// ⑧ (m23-ee-2c-2b) — a pin via DEEP-EQUALITY against an expected list. `eq(RECV,
// RHS)` asserted BEFORE the site, where RECV is matched by BYTE-IDENTICAL
// source text against the receiver — not by root identifier. `st` is
// reassigned via plain `st = await cmd(...)` at least ten times in
// m23m3c-stems-dialog.mjs, so a root-only match would let some UNRELATED
// `st`'s eq() pin clear a receiver it never described (exactly the cross-
// epoch hazard ⑦'s own comment above documents finding and fixing).
//
//   m23m3c-stems-dialog.mjs:145/147 — eq(st.plannedFiles, STEMS), STEMS a
//     3-element MODULE-LEVEL literal: STRENGTH A — if that leg passes,
//     st.plannedFiles is exactly 3 elements, full stop.
//   m23m3c-stems-dialog.mjs:193/197 — eq(onDisk, [...promised].sort()); RHS
//     is NOT a literal (`promised` traces back through several `await`s this
//     scanner does not follow) — cleared under the WEAKER "pinned-visible"
//     reading only: an unexpectedly-empty `onDisk` reddens :193's eq() leg
//     PROVIDED `promised` itself is non-empty, which this scanner cannot
//     prove. Reported as strength B, not silently upgraded to strength A.
//
// Excludes `eq(RECV, [])` and an Identifier RHS that resolves to an empty
// array literal (an emptiness ASSERTION, not a pin — mirrors findCountPin's
// `lit.value <= 0` exclusion) and requires the eq() itself be asserted inside
// a check(/ck( call.
function findEqPin(ancestors, recvNode, site, code, ast) {
  const recvText = txt(code, recvNode);
  for (let i = ancestors.length - 1; i >= 0; i--) {
    const a = ancestors[i];
    const body = a.type === "BlockStatement" || a.type === "Program" ? a.body : null;
    if (!body) continue;
    for (const stmt of body) {
      if (stmt.start >= site.start) break;   // preceding-only, per the item's own wording ("immediately before")
      let found = null;
      walk.fullAncestor(stmt, (n, _s, anc2) => {
        if (found || n.type !== "CallExpression") return;
        if (n.callee.type !== "Identifier" || n.callee.name !== "eq") return;
        const [recvArg, rhsArg] = n.arguments;
        if (!recvArg || !rhsArg) return;
        if (txt(code, recvArg) !== recvText) return;

        // Resolve an Identifier RHS one hop — only to tell `eq(x, [])` (pins
        // nothing) from a real fixed list, and to classify strength for the
        // report. Resolution failure does NOT disqualify the pin: it just
        // means the derived-RHS (strength B) branch below.
        let rhsResolved = rhsArg;
        if (rhsArg.type === "Identifier") {
          let decl = null;
          walk.simple(ast, {
            VariableDeclarator(d) {
              if (d.id.type === "Identifier" && d.id.name === rhsArg.name && !decl) decl = d;
            },
          });
          if (decl?.init) rhsResolved = decl.init;
        }
        if (rhsResolved.type === "ArrayExpression" && rhsResolved.elements.length === 0) return;   // pins nothing

        const asserted = anc2.some((a2) => a2.type === "CallExpression" &&
          a2.callee.type === "Identifier" && /^(check|ck)$/.test(a2.callee.name));
        if (!asserted) return;

        const strength = rhsResolved.type === "ArrayExpression" && rhsResolved.elements.length > 0
          ? `A (fixed list, ${rhsResolved.elements.length} element(s))`
          : "B (derived RHS, pinned-visible — a mismatch reddens this leg, non-emptiness not independently proven)";
        found = `${txt(code, n).slice(0, 70)} — strength ${strength}`;
      });
      if (found) return found;
    }
  }
  return null;
}

const files = readdirSync(GATES).filter((f) => f.endsWith(".mjs") && !f.startsWith("_")).sort();
const rows = [];
const parseFails = [];

for (const f of files) {
  const code = src(f);
  let ast;
  try {
    ast = acorn.parse(code, { ecmaVersion: "latest", sourceType: "module", locations: true });
  } catch (e) {
    // ⚠️ A FILE THAT DID NOT PARSE IS UNMEASURED, NOT CLEAN. Recorded loudly.
    parseFails.push(`${f}: ${e.message}`);
    continue;
  }

  walk.fullAncestor(ast, (node, _st, ancestors) => {
    if (node.type !== "CallExpression") return;
    const callee = node.callee;
    if (callee.type !== "MemberExpression" || callee.computed) return;
    const method = callee.property.name;
    if (method !== "every" && method !== "some" && method !== "filter") return;

    const anc = ancestors.slice(0, -1); // drop self

    // `.filter(...)` only counts when its .length is compared against 0 —
    // "no bad rows" is vacuous exactly when there were no rows at all.
    let kind = method;
    if (method === "filter") {
      const parent = anc[anc.length - 1];
      const gp = anc[anc.length - 2];
      const isLen = parent && parent.type === "MemberExpression" && parent.property.name === "length";
      if (!isLen) return;
      const cmpZero =
        gp && gp.type === "BinaryExpression" &&
        /^(===|==|<=|<|!==|!=|>|>=)$/.test(gp.operator) &&
        ((gp.right.type === "Literal" && gp.right.value === 0) ||
         (gp.left.type === "Literal" && gp.left.value === 0));
      if (!cmpZero) return;
      kind = "filter().length==0";
    }

    const recvNode = callee.object;
    const recvText = txt(code, recvNode).slice(0, 44);
    const recvRoot = rootIdent(recvNode);
    const recvPath = memberPath(recvNode);   // m23-gl — null if not structurally resolvable

    // A receiver that is ITSELF an inline array literal can never be runtime-empty.
    let provenance, reason;
    let recvDecl = null;   // hoisted so the blind-spot 2/3/4 checks below can reuse it
    if (recvNode.type === "ArrayExpression") {
      [provenance, reason] = recvNode.elements.length
        ? ["LITERAL", `inline array literal, ${recvNode.elements.length} element(s)`]
        : ["RUNTIME", "inline EMPTY array literal"];
    } else if (!recvRoot) {
      [provenance, reason] = ["RUNTIME", `receiver is an expression: ${recvText}`];
    } else {
      // ⚠️ NEAREST **PRECEDING** DECLARATOR, not the first one in the file.
      // These gates reuse short names across sibling blocks — m23c2 has THREE
      // `s`: `for (const s of run.samples)` at :355 (a for-of declarator, so
      // `init` is null), `const s = on.samples` at :369, `const s = off.samples`
      // at :441. Taking the first match reported `UNKNOWN — declared without an
      // initialiser` for a receiver that is plainly a runtime member read, i.e.
      // it mis-attributed provenance, the census's whole discriminator.
      let decl = null;
      walk.simple(ast, {
        VariableDeclarator(d) {
          if (d.id.type !== "Identifier" || d.id.name !== recvRoot) return;
          if (d.start >= node.start) return;                 // must precede the site
          if (!decl || d.start > decl.start) decl = d;        // keep the closest
        },
      });
      // A for-of/for-in declarator has no `init`; the iterated expression is the
      // real source, and iterating a runtime collection is itself runtime.
      let forOf = null;
      if (decl && !decl.init) {
        walk.fullAncestor(ast, (n2, _s, anc2) => {
          if (n2 !== decl) return;
          const p = anc2[anc2.length - 2];
          if (p && (p.type === "ForOfStatement" || p.type === "ForInStatement")) forOf = p.right;
        });
      }
      // ⚠️ THE `else` BELOW MUST STAY BOUND TO `else if (decl)`. An earlier edit
      // inserted the EMPTY-LITERAL block BETWEEN them, which silently re-bound the
      // else to the EMPTY-LITERAL `if` — so every successfully-resolved receiver
      // got overwritten with "not declared in-file" and counted RUNTIME. It showed
      // up as the at-risk count RISING (32 -> 37) right after I added two CLEARING
      // rules, which is impossible and is the only reason I caught it. A dangling
      // else does not fail; it just quietly makes everything look at-risk.
      if (forOf) [provenance, reason] = ["RUNTIME", `for-of over ${txt(code, forOf).slice(0, 50)}`];
      else if (decl) [provenance, reason] = classifyInit(decl.init, code);
      else [provenance, reason] = ["RUNTIME", `\`${recvRoot}\` not declared in-file (param/import)`];

      recvDecl = decl;   // used by blind-spot 2/3/4 checks below and by findSomeLegPin()

      // ⑨ (m23-ee-2c-2b) — HELPER-PARAM: a receiver that is DIRECTLY the
      // immediately-enclosing function's OWN PARAMETER. The exact mirror of
      // HELPER-RETURN (localHelperCall(), above) — this tool cannot see
      // across the CALL BOUNDARY in the other direction either: whoever calls
      // the enclosing helper decides what gets passed, so this is NOT a
      // clearing rule, just a tag distinguishing "go read one function's call
      // sites" from a genuine unknown. m23do-menubar.mjs:163 —
      // `needle.every(…)` inside `function hasConsecutiveRun(haystack, needle)`
      // — cleared by inspection (every call site passes an array literal) but
      // NOT by this tool.
      //
      // ⚠️ ONLY when the receiver IS the parameter directly
      // (`recvNode.type === "Identifier"`) — NOT a property read off it.
      // Mirrors the identical restriction on HELPER-RETURN below, for the
      // identical reason: `m23c2-follow-playhead.mjs:124`'s `m.runList` has
      // `m` as a parameter, but knowing `m` is a parameter says nothing about
      // `m.runList`'s length — that would overstate what this tag means.
      // Placed as a SEPARATE statement after the if/else chain above, not
      // interleaved into it — this file's own history (the comment just
      // above) documents a dangling-`else` bug from exactly that shape.
      if (!decl && !forOf && recvNode.type === "Identifier") {
        const owner = enclosingParamOwner(anc, recvRoot);
        if (owner) {
          provenance = "HELPER-PARAM";
          reason = `receiver IS \`${owner}\`'s own parameter \`${recvRoot}\` — interprocedural: `
                 + `READ EVERY CALL SITE, this tool cannot see across the call boundary`;
        }
      }

      // BLIND SPOT 2 (m23-ee-2c), the map-chain half — TRANSITIVE fixed-bound
      // through a length-preserving chain over an IDENTIFIER base (the
      // EMPTY-LITERAL branch just below handles the accumulator-of-an-
      // accumulator half; this one handles `restored = tracks.map(...)`).
      // m23g1-arrange-multiselect.mjs:387: `const restored = tracks.map((t) =>
      // clipsOf(ov, t));` — classifyInit's own inline-chain check (above, in
      // classifyInit) only unwinds a chain sitting DIRECTLY over an array
      // LITERAL; here the base is the identifier `tracks`, which is itself a
      // for-of-filled accumulator over a 3-element literal (blind spot 1) —
      // so `restored.length === tracks.length === 3`, always.
      if (provenance === "RUNTIME" && decl?.init) {
        const chainBase = lengthPreservingChainBase(decl.init);
        if (chainBase) {
          const baseFixed = resolvedFixedBound(ast, chainBase.base, code, 0);
          if (baseFixed) {
            provenance = "LITERAL";
            reason = `${chainBase.ops.join("/")} over \`${chainBase.base}\`, itself ${baseFixed} — length-preserving, cannot be empty`;
          }
        }
      }

      // BLIND SPOT 4 (m23-ee-2c) — tag (do NOT clear) a receiver that comes
      // from a call to a LOCAL helper function. See localHelperCall()'s
      // header comment above for why this is a tag, not a clearing rule.
      //
      // ⚠️ ONLY when the receiver IS the helper's return value directly
      // (`recvNode.type === "Identifier"`) — NOT when it's a property read
      // off that return value. m23m3c-stems-dialog.mjs:147 —
      //     const st = await cmd(ws, "debug.exportDialog", { open: true });
      //     …st.plannedFiles.some(…)…
      // The receiver here is `st.plannedFiles`, a MemberExpression; `st`
      // (recvRoot) resolves to the `cmd(...)` call, but reading `cmd()`'s
      // BODY tells a reader nothing about `plannedFiles.length` — `cmd` is a
      // generic WS-request wrapper with no idea what `plannedFiles` is. That
      // is NOT "go read one function", it's a genuine unknown, so tagging it
      // HELPER-RETURN would make `notClearedByProvenance` overstate the easy
      // bucket. Mirrors the existing LITERAL-CHAIN downgrade a few lines
      // below, which exists for the identical hazard on the LITERAL side.
      if (provenance === "RUNTIME" && decl?.init && recvNode.type === "Identifier") {
        const helper = localHelperCall(decl.init, ast);
        if (helper) {
          provenance = "HELPER-RETURN";
          reason = `${helper.awaited ? "awaited local helper" : "local helper"} \`${helper.name}(…)\` `
                 + `— READ IT: length may be fixed by construction`;
        }
      }

      // An empty-literal accumulator is only at risk if its fill can be skipped.
      if (provenance === "EMPTY-LITERAL") {
        const fixed = fixedFillCount(ast, recvRoot, code);
        [provenance, reason] = fixed
          ? ["LITERAL", `accumulator filled by a ${fixed}`]
          : ["RUNTIME", "empty-literal accumulator, fill NOT provably fixed-bound"];
      }
      // A chained receiver (x.map(...).filter(...)) is runtime regardless of x's decl.
      if (recvNode.type !== "Identifier" && provenance === "LITERAL") {
        provenance = "LITERAL-CHAIN";
        reason += "; but receiver is a CHAIN off it";
      }
    }

    // Which call encloses this site? Reported, never guessed at.
    let encl = null;
    for (let i = anc.length - 1; i >= 0; i--) {
      const a = anc[i];
      if (a.type === "CallExpression" && !(a.callee.type === "MemberExpression" && a.callee.object === node)) {
        encl = a.callee.type === "Identifier" ? a.callee.name : txt(code, a.callee).slice(0, 24);
        break;
      }
      if (/Function/.test(a.type)) break;
    }

    // ⭐ (m23-fb) — DETAIL-ARG override. Argument index 2 (0-based) of a
    // `check(`/`ck(` call is the DETAIL string — see detailArgCall()'s header
    // comment, far above, for the full reasoning. Deliberately computed and
    // applied AFTER every other provenance/reason classification above (the
    // `if (recvNode.type === "ArrayExpression") { … } else { … }` block) and
    // BEFORE `rows.push`, so it OVERRIDES whatever provenance the receiver's
    // own dataflow produced — position in the enclosing call is a stronger,
    // independent clearing basis than any of that, per the item brief
    // ("needs no dataflow at all"). Does not touch `guard`/`pin`/etc., which
    // stay reported as `null` for a DETAIL-ARG site — this is a different,
    // simpler clearing reason, not an instance of any existing idiom.
    const detailArg = detailArgCall(anc, node);
    const isDetailArg = Boolean(detailArg && detailArg.index === 2);
    if (isDetailArg) {
      provenance = "DETAIL-ARG";
      reason = `argument ${detailArg.index + 1} (detail) of \`${detailArg.callee}(\` — the diagnostic `
             + `string printed on failure; cannot affect the check's verdict`;
    }

    // ⚠️⚠️ POLARITY IS HALF THE AXIS, AND COUNTING WITHOUT IT INFLATES THE RESULT.
    // On an EMPTY collection: `[].every(f)` is **true**, `[].some(f)` is **false**.
    // So vacuity is dangerous only when the empty-value equals the value the
    // assertion wants:
    //     every(…)      -> true  on empty -> VACUOUS PASS          ⚠️ dangerous
    //     !every(…)     -> false on empty -> fails loudly          ✅ self-defending
    //     some(…)       -> false on empty -> fails loudly          ✅ self-defending
    //     !some(…)      -> true  on empty -> VACUOUS PASS          ⚠️ dangerous
    // A positive `.some()` is its OWN emptiness guard — it reddens on a short run
    // without any count pin. Treating all 130 sites as one population would have
    // reported 53 at-risk when a third of them cannot fail this way at all.
    let neg = false;
    for (let i = anc.length - 1; i >= 0; i--) {
      const a = anc[i];
      if (a.type === "UnaryExpression" && a.operator === "!") { neg = !neg; continue; }
      if (a.type === "BinaryExpression" && /^(===|==)$/.test(a.operator) &&
          ((a.right.type === "Literal" && a.right.value === false) ||
           (a.left.type === "Literal" && a.left.value === false))) { neg = !neg; continue; }
      if (a.type === "MemberExpression" || a.type === "ChainExpression") continue;
      break;
    }
    const emptyValue = (method === "every") !== neg;   // what the site evaluates to on []
    const selfDefending = kind !== "filter().length==0" && !emptyValue;

    // Check every name in the derivation chain, nearest first — a guard on the
    // source collection bounds everything length-monotone derived from it.
    const chain = recvRoot ? derivationChain(ast, recvRoot, code) : [];
    let guard = null, pin = null, via = null, pinScope = null;
    for (const nm of chain) {
      // m23-gm — `recvPath` (fault ③) only applies on the site's own,
      // un-hopped receiver, mirroring the identical `nm === recvRoot ? recvPath
      // : null` threading already used for findCountPin() below — a chain hop
      // is a bare root name with no member path of its own to enforce.
      guard = findLengthGuard([...anc, node], nm, code, node, nm === recvRoot ? recvPath : null);
      if (!guard) {
        // m23-ex — findCountPin() now returns { found, unresolved }: a
        // candidate pin must resolve to the SAME binding as the site's own
        // `nm`, and if `nm` itself can't be placed in any scope, `pin` stays
        // null but that refusal is recorded (pinScope) so it doesn't look
        // identical to "no pin exists" — see findCountPin()'s own header.
        // Recorded only for the name that ultimately decided the outcome
        // (whichever `nm` the loop stops on, success or not) — an
        // unresolved attempt on an EARLIER chain name that a LATER name goes
        // on to clear normally is not worth reporting as a limitation.
        //
        // ⚠️ m23-gl — CONFIRMED BY PROBE, NOT JUST INFERRED: `pinScope` is
        // OVERWRITTEN on every loop iteration, not accumulated. If an EARLIER
        // chain entry sets a meaningful `pinScope` (UNRESOLVED or, new here,
        // PROPERTY-MISMATCH) and a LATER entry finds nothing AND has nothing
        // to report either, that later `null` silently erases the earlier
        // entry's reason — `cleared`/`notCleared` stay correct either way
        // (this only touches the DIAGNOSTIC string, never the verdict), but
        // a reader chasing "why didn't this clear" sees `pinScope: null` and
        // has no way to tell that from "no candidate was ever looked at",
        // even though one was found and rejected. Confirmed with `restored`
        // (derived from `tracks` by `.map()`) carrying a property-mismatched
        // pin on `restored` itself, `tracks` on the second hop offering no
        // candidate at all: final `pinScope` came back `null`. Deliberately
        // left as-is — this exact "recorded only for the deciding entry"
        // shape already existed for UNRESOLVED before this item (see the
        // paragraph just above) and fixing it means changing what BOTH
        // diagnostics accumulate across chain entries, a strictly larger
        // change than this item's own scope (which is the CLEARING rule,
        // not the chain-loop's diagnostic bookkeeping). If this ever needs
        // fixing, make `pinScope` sticky (first non-null reason wins, reset
        // only when `guard || pin` actually succeeds) rather than
        // overwritten-every-iteration.
        //
        // m23-gl — the property-axis check (recvPath) only applies on the
        // FIRST chain entry (`nm === recvRoot`, i.e. no hop): that is the
        // only case where `recvNode` — the actual expression this row is
        // about — is the thing being matched against. A hop's own `nm` is
        // just a bare root name with no member path of its own to enforce
        // (see derivationChain()'s and findCountPin()'s headers) — passing
        // `null` there is exactly the pre-fix root-only match, unchanged.
        // A DIRECT CONSEQUENCE: `r.propertyMismatch` can only ever come back
        // true when `nm === recvRoot` (countPinInStmt only sets it inside
        // its own `if (recvPath)` guard, and recvPath is null on every hop),
        // so `recvText` — the SITE's own receiver text, already computed
        // above for the row itself — is always the right thing being
        // described here, not just "whatever `nm` currently is".
        const r = findCountPin(anc, nm, node, code, nm === recvRoot ? recvPath : null);
        pin = r.found;
        pinScope = r.unresolved
          ? `UNRESOLVED — \`${nm}\` could not be placed in any scope on the path`
          : r.propertyMismatch
            ? `PROPERTY-MISMATCH — a candidate pin shared \`${nm}\`'s root but described a different property than \`${recvText}\` itself (m23-gl)`
            : null;
      }
      if (guard || pin) { via = nm === recvRoot ? null : nm; break; }
    }

    // BLIND SPOT 3 (m23-ee-2c) — idiom D, findSomeLegPin() above. Only tried
    // when idioms A/B found nothing, and only against the receiver ITSELF
    // (not the derivation chain — this idiom is specific to a `.filter(P)`
    // receiver with a preceding, asserted, same-predicate `.some(P)`, not to
    // a monotone-derived one).
    const someLegPin = (!guard && !pin) ? findSomeLegPin(ast, recvDecl, code, node) : null;

    // ⑥/⑧ (m23-ee-2c-2b) — idioms E and F, findJoinPin()/findEqPin() above.
    // Same precedence rule as idiom D: only tried once A/B/D found nothing,
    // and only against the receiver itself, not the derivation chain (both
    // idioms match on the receiver's own SOURCE TEXT, which a chain hop would
    // break).
    const joinPin = (!guard && !pin && !someLegPin) ? findJoinPin(anc, recvNode, node, code) : null;
    const eqPin = (!guard && !pin && !someLegPin && !joinPin) ? findEqPin(anc, recvNode, node, code, ast) : null;

    rows.push({
      file: f,
      line: node.loc.start.line,
      kind,
      encl: encl || "-",
      recv: recvText,
      provenance,
      reason,
      guard,                                   // idiom A — inline conjunct
      pin,                                     // idiom B — leading count-pin leg
      pinScope,                                // m23-ex/m23-gl — non-null iff idiom B's OWN receiver name could
                                                // not be resolved to a binding (UNRESOLVED), OR a same-root
                                                // candidate was rejected on the property axis (PROPERTY-MISMATCH)
                                                // — either way, a reason `pin: null` alone would not show
      someLegPin,                              // idiom D — preceding, asserted .some() leg, same predicate
      joinPin,                                 // idiom E — equality on a derived .map().join() (⑥)
      eqPin,                                   // idiom F — deep-equality (eq) pin against an expected list (⑧)
      negated: neg,
      selfDefending,                           // idiom C — polarity fails on empty
      cleared: isDetailArg || Boolean(guard || pin || someLegPin || joinPin || eqPin) || provenance === "LITERAL" || selfDefending,
      clearedBy: isDetailArg ? `DETAIL-ARG (argument 3 of \`${detailArg.callee}(\` — diagnostic string, cannot affect the verdict)`
               : provenance === "LITERAL" ? "literal receiver"
               : guard ? "inline .length conjunct"
               : pin ? "leading count-pin leg"
               : someLegPin ? "preceding asserted .some() leg (same predicate)"
               : joinPin ? "preceding pin via equality on a derived .map().join()"
               : eqPin ? "preceding pin via deep-equality (eq) against an expected list"
               : selfDefending ? `polarity (${neg ? "!" : ""}${method} is false on empty — reddens instead)`
               : null,
      via,                                     // guard found on a SOURCE collection, not the receiver
    });
  });
}

// The tool counts, not the consumer — see the `notCleared` note in the header.
const notClearedRows = rows.filter((r) => r.cleared === false);
const notCleared = notClearedRows.length;

// ⚠️ notClearedByProvenance (added m23-ee-2c) — how much of `notCleared` is a
// genuine unknown versus "read one function" (HELPER-RETURN, blind spot 4).
// Same motivation as the `notCleared` field itself: a consumer that treats
// the whole `notCleared` total as equally actionable over-counts by exactly
// the HELPER-RETURN sites. Read this field; don't re-derive it by filtering
// `rows` on a guessed `provenance` string.
const notClearedByProvenance = {};
for (const r of notClearedRows) {
  notClearedByProvenance[r.provenance] = (notClearedByProvenance[r.provenance] || 0) + 1;
}

console.log(JSON.stringify(
  { rows, parseFails, filesScanned: files.length, notCleared, notClearedByProvenance }, null, 1));
