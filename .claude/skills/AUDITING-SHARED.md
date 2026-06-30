# Auditing — Shared Methodology

Common foundation for the three deep-audit skills. Each skill **extends** this
file with its own unique framework — read this first, then read the
auditor-specific rules and process in the skill.

- `feynman-auditor` — first-principles logic-bug hunting (Question Framework + Execution Process)
- `state-inconsistency-auditor` — coupled-state desync hunting (Abstract Pattern + Audit Process + Red Flags + Verification Gate)
- `nemesis-auditor` — fuses both in an iterative back-and-forth loop (Execution Model + Pipeline)

---

## When NOT to Use (shared baseline)

None of these auditors is the right tool for:

- Quick pattern-matching scans where you only need known vulnerability patterns
- Simple spec compliance checks
- Report generation from existing findings

(Individual skills add their own exclusions — e.g. state-inconsistency defers
pure first-principles logic bugs to `/feynman`.)

---

## Language Adaptation

When you start, **detect the language** and adapt terminology. The questions and
methodology are universal; only the vocabulary changes.

| Concept | Solidity | Move | Rust | Go | C++ |
|---------|----------|------|------|----|-----|
| Module/unit | contract | module | crate/mod | package | class/namespace |
| Entry point | external/public fn | public fun | pub fn | Exported fn | public method |
| Access guard | modifier | access control (friend, visibility) | trait bound / #[cfg] | middleware / auth check | access specifier |
| Caller identity | msg.sender | &signer | caller param / Context | ctx / request.User | this / session |
| Error/abort | revert / require | abort / assert! | panic! / Result::Err | error / panic | throw / exception |
| State storage | storage variables | global storage / resources | struct fields / state | struct fields / DB | member variables |
| Mapping | mapping(k => v) | Table\<K, V\> / SmartTable | HashMap / BTreeMap | map[K]V | std::map / unordered_map |
| Delete | delete mapping[key] | table::remove | map.remove(&key) | delete(map, key) | map.erase(key) |
| Event/log | emit Event() | event::emit() | emit! / log | EventEmit() | signal / callback |
| Internal call | internal function | friend function | pub(crate) fn | unexported func | private method |
| External call | .call() / interface | cross-module call | CPI (Solana) | RPC / HTTP | virtual call |
| Checked math | SafeMath / 0.8+ auto | built-in overflow abort | checked_add / saturating | math/big / manual check | safe int libs |
| Test framework | Foundry / Hardhat | Move Prover / aptos move test | cargo test | go test | gtest / catch2 |
| Value/assets | ETH, ERC-20, NFTs | APT, Coin\<T\>, tokens | SOL, SPL tokens, funds | any value type | any value type |

**IMPORTANT:** Do NOT force Solidity terminology onto non-Solidity code. Use the
language's native concepts. The questions stay the same — the vocabulary adapts.

---

## Core Philosophy

```
"What I cannot create, I do not understand." — Feynman

Applied to auditing: If you cannot explain WHY a line of code exists,
in what order it MUST execute, and what BREAKS if it changes —
you have found where bugs hide.
```

Pattern matchers find KNOWN bug classes. These auditors find UNKNOWN bugs by
reasoning from first principles — questioning the developer's reasoning at every
decision point (Feynman) and mapping the structural invariants that couple state
(State Inconsistency). They complement checklists and automated scanners by
surfacing the logic flaws, missing guards, broken invariants, and state-desync
bugs that pattern-matching misses.

---

## Core Rules (shared baseline)

These apply to every auditor. Each skill's own Core Rules section extends them
with method-specific rules.

```
RULE — EVIDENCE-BASED FINDINGS ONLY (evidence or silence)
Every finding must include:
- The specific code (file + exact line numbers)
- The question or invariant that exposed it
- A concrete trigger scenario proving the bug
- Why the current code fails in that scenario
- For CRITICAL/HIGH/MEDIUM: verification (see each skill's Verification Gate)
Never use "could potentially" / "might be vulnerable". Evidence or silence.

RULE — QUESTION EVERYTHING, REASON FROM FIRST PRINCIPLES
Never accept code at face value, and never fall back to pattern-matching
("this looks like reentrancy"). Every line exists because a developer made a
decision; reason about what THIS specific code actually does.

RULE — READ BEFORE YOU CLAIM (anti-hallucination)
Read the actual code before questioning it. Verify guards, initializers, default
values, and called functions by reading them. Never invent code, never assume a
guard exists without confirming it, always cite exact file paths and line
numbers, and use the detected language's native terminology. Each skill's
Anti-Hallucination Protocol section lists its method-specific NEVER/ALWAYS items.
```
