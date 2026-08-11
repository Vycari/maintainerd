# Language-specific detection — audit-architecture

The concrete greps, tool invocations and thresholds for each language the toolkit ships rules for.
**Run only the block matching `config.language`** — the other is noise for this repo. If neither
matches, fall back to the language-generic checks in the category table and say so in the report.

The judgment lives in SKILL.md's category table; this file is the mechanics.

## Python

Run this block when `config.language == "python"`.

| Category                              | Detection                                                                                                                                                                                       | Default routing                                                                     |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **Oversized files**                   | `find config.paths.source -name '*.py' -exec wc -l {} \; \| sort -rn`; flag `.py` files >500 lines (raise the bar for known-large modules — e.g. a generated-ish ORM/models file at >800, a `**/router.py` at >600; tune per repo). Don't use `wc -l config.paths.source/**/*.py` — that needs bash 4+ with `shopt -s globstar` and silently no-ops on macOS's default bash 3.2. Use `\;` not `+` so each `wc` call sees one file and skips the cumulative `N total` row that would otherwise sort to the top | **Issue** — splitting a big module is a design decision                             |
| **`Any` / `cast(Any, ...)` overuse**  | `grep -rEn ': Any([^A-Za-z0-9_]\|$)\|-> Any([^A-Za-z0-9_]\|$)\|cast\(Any([^A-Za-z0-9_]\|$)' config.paths.source` (ignore `from typing import Any` lines). Use `-E` with an explicit non-word-character class: `\>` and `\|` are GNU/BSD **extensions**, not POSIX BRE, so a BRE pattern relying on them is not portable                                                                                                    | **PR** if 1–3 sites in a single file with obvious correct type; **issue** otherwise |
| **`# type: ignore` / `# noqa`**       | `grep -rn '# type: ignore\|# noqa' config.paths.source`                                                                                                                                         | **PR** if the suppression is removable today; **issue** with explanation if not     |
| **Bare / swallowed excepts**          | `grep -rn 'except:\|except Exception:[[:space:]]*pass\|except Exception:[[:space:]]*\.\.\.\|except Exception:[[:space:]]*$' config.paths.source` plus reading for the `try: ... except Exception: logger.warning(...); return None` shape that silently masks bugs. (POSIX `[[:space:]]` instead of `\s` because BSD grep treats `\s` as literal in BRE; the `$`-anchored arm is listed *last* because BSD grep silently drops it from non-final alternation positions) | **Issue** — silent failure is a cardinal sin (see `config.guidelines.coding`)        |
| **Missing test files**                | For each `config.paths.source/<subsystem>/`, check whether *any* test under `config.paths.tests` references its module path. Subsystems with zero test imports are the strong signal                                 | **Issue** — writing a first test for a previously-untested subsystem is non-trivial |
| **Dead exports / unused modules**     | `uv run vulture config.paths.source config.paths.tests --min-confidence 80`. Pass the test root too so vulture sees test-only references and doesn't flag e.g. fixture-imported helpers as dead. Triage the report: vulture over-reports on FastAPI route handlers (decorator-registered, never imported by name), pydantic field defaults, SQLAlchemy column attributes, and anything in `app.state` wiring — verify each hit by grepping `config.paths.source` + `config.paths.tests` for the symbol before routing it | **PR** — deletion is mechanical and reversible                                      |
| **`print()` in library code**         | `grep -rn '^[[:space:]]*print(' config.paths.source` (excluding a CLI/`scripts/` dir if one exists; CLI scripts may legitimately print). Convention is `logger = logging.getLogger(__name__)`           | **PR** — mechanical replacement                                                     |
| **Naive `datetime` usage**            | `grep -rn 'datetime\.now()\|datetime\.utcnow()\|\.astimezone([[:space:]]*)' config.paths.source`. `datetime.utcnow()` is deprecated since Python 3.12; `dt.astimezone()` with no argument resolves to the container's local zone (UTC in prod — silently misrenders for non-UTC users — see `config.guidelines.invariants`) | **PR** if local fix; **issue** if it touches the user-facing render path            |
| **Sync DB calls in async paths**      | `grep -rEn 'session\.(execute\|commit\|flush\|refresh\|get)\(' config.paths.source` and visually confirm each is `await`-ed. In an all-async codebase a missing `await` is a latent bug. **`session.add()` is deliberately excluded — it is synchronous and returns `None`**, so "fixing" it with `await` turns working code into `TypeError: object NoneType can't be used in 'await' expression`                | **PR** — adding `await` is mechanical                                               |
| **DRY violations**                    | Manual reading: look for near-duplicate helper functions, repeated control-flow blocks (>10 lines duplicated >2 places), parallel `if`/`match` ladders, copy-pasted third-party client setup, copy-pasted header parsing | **Issue** — extraction is a design decision                                         |
| **Weak abstractions**                 | Manual reading: "god" service classes (>15 public methods), routers that mix unrelated concerns, settings objects passed everywhere instead of focused dependencies, `**kwargs` plumbing where a typed dataclass would do | **Issue**                                                                           |
| **Improper typing**                   | `Optional[X]` instead of `X \| None` (UP007 should catch — skip if so); `dict`/`list` without parameters in signatures; index signatures (`dict[str, Any]`) where a `TypedDict` or pydantic model would carry the invariant | **PR** if local fix; **issue** if structural                                        |

You're not limited to this table — if a senior Python reviewer would flag something else (mutable default arguments, shared mutable state in module globals, `asyncio.create_task` without a reference, swallowed task exceptions), capture it. Just keep the routing rule: mechanical and small → PR; structural or judgment-heavy → issue.

## TypeScript

Run this block when `config.language == "typescript"`.

| Category                              | Detection                                                                                                                                                                            | Default routing                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| **Oversized files**                   | `find config.paths.source -name '*.ts' -exec wc -l {} \; \| sort -rn`; flag `.ts` files >700 lines (>1000 for the main entry file, e.g. `src/main.ts`)                                                                 | **Issue** — splitting a big file is a design decision                               |
| **`any` / `as any` overuse**          | `grep -rn ': any\b\|as any' config.paths.source`                                                                                                                                    | **PR** if 1–3 sites in a single file with obvious correct type; **issue** otherwise |
| **`@ts-ignore` / `@ts-expect-error`** | `grep -rn '@ts-ignore\|@ts-expect-error' config.paths.source`                                                                                                                       | **PR** if the suppression is removable today; **issue** with explanation if not     |
| **Missing test files**                | For each `.ts` under `config.paths.source` (via `find`, excluding barrels, types, declarations), check the matching `*.test.ts` under `config.paths.tests` exists                                          | **Issue** — writing tests for a previously-untested module is non-trivial           |
| **Dead exports**                      | `npm run knip` (or `grep` for each exported symbol's references across `config.paths.source` and `config.paths.tests`); flag exports with 0 external references that aren't entry points or re-exported via the index barrel | **PR** — deletion is mechanical and reversible                                      |
| **DRY violations**                    | Manual reading: look for near-duplicate helper functions, repeated control-flow blocks (>10 lines duplicated >2 places), parallel `if`/`switch` ladders                             | **Issue** — extraction is a design decision                                         |
| **Weak abstractions**                 | Manual reading: look for "god" interfaces (>15 members), classes that mix unrelated responsibilities, settings objects passed everywhere instead of focused dependencies            | **Issue**                                                                           |
| **Improper typing**                   | `Object`, `Function`, `{}` as types; non-null assertions (`!`) in non-trivial spots; index signatures where a discriminated union would do                                          | **PR** if local fix; **issue** if structural                                        |
| **Console misuse**                    | `grep -rn 'console\.\(log\|debug\|error\|warn\)' config.paths.source` — repo convention is a structured logger, not `console` (see `config.guidelines.coding` / `config.guidelines.invariants`) | **PR** — mechanical replacement                                                     |
| **Circular imports**                  | `grep` for the known smell: `import { X } from './foo'` in a file that `foo` also imports from                                                                                      | **Issue**                                                                           |

You're not limited to this table — if a senior TypeScript reviewer would flag something else (dead branches, swallowed errors, magic numbers in agent loops), capture it. Just keep the routing rule: mechanical and small → PR; structural or judgment-heavy → issue.

## Order to run the sweep

Fast-to-slow, for the block matching `config.language`. This is the same set of checks as the table
above — the table says what each finding *is* and how to route it; this says what order to run them
in so the cheap greps surface work before the slow reading passes.

**Python:**

1. **Oversized files** — `find config.paths.source -name '*.py' -exec wc -l {} \; | sort -rn`. Note anything over the threshold. (Avoid `wc -l config.paths.source/**/*.py`; that depends on bash globstar and silently expands to literal text on macOS's default bash 3.2. `-exec ... \;` per file rather than `+` keeps `wc`'s cumulative "total" row out of the ranked output.)
2. **`Any` / `cast(Any)` / `# type: ignore` density** — the `grep -rn`s. Tally per-file counts. Ignore the `from typing import Any` import line.
3. **`print()` in library code** — one `grep`. Each hit is a finding (or all hits in one file roll into one PR).
4. **Bare / swallowed excepts** — one `grep`, then read the surrounding 5 lines on each hit. The shape that matters is "logged-and-swallowed" — a true silent failure.
5. **Naive `datetime`** — `grep` for `.now()`, `.utcnow()`, and the no-arg `.astimezone()`. Cross-check against the timezone rule in `config.guidelines.invariants`.
6. **Sync DB calls missing `await`** — `grep` and visually inspect; the linter doesn't catch these without a dedicated plugin.
7. **Dead exports** — `uv run vulture config.paths.source config.paths.tests --min-confidence 80`. Vulture should be a dev dep; if the command errors with "command not found," that's a setup bug worth flagging in the report, not a reason to fall back to grep. Triage every hit before routing — vulture over-reports on FastAPI route handlers (decorator-registered, never referenced by name), pydantic field attributes, SQLAlchemy column descriptors, and `app.state` lifespan wiring. For each candidate, grep `config.paths.source` and `config.paths.tests` for the symbol; only route it as a finding if the grep also comes up empty (or finds only the definition site). Lowering `--min-confidence` below 80 is rarely productive — the noise floor swamps the signal.
8. **Missing tests** — list `config.paths.source/<subsystem>/` directories, grep `config.paths.tests` for any import of each subsystem. Zero hits → finding. Note that tests aren't always a 1:1 file mirror — many tests cross several modules in one file.
9. **DRY violations** — read the larger files (top 10 by line count) and look for repeated blocks. Judgment-heavy step; don't force findings if nothing obvious surfaces.
10. **Weak abstractions** — same reading pass; note service classes over 15 public methods, routers with mixed responsibilities.
11. **Improper typing / circular imports / other** — opportunistic.

**TypeScript:**

1. **Oversized files** — `find config.paths.source -name '*.ts' -exec wc -l {} \; | sort -rn`. Note anything over the threshold. (Same globstar trap as the Python block: `wc -l config.paths.source/**/*.ts` silently misses nested files on bash 3.2.)
2. **`any` / `as any` / `@ts-ignore` density** — three `grep -rn` invocations. Tally per-file counts.
3. **Console misuse** — one `grep` against `config.paths.source`. Each hit is a finding (or all hits in one file roll into one PR).
4. **Dead exports & unused deps** — run `npm run knip` if configured. It resolves entry points (main, test files, scripts) and follows re-exports and type-only references through the TypeScript program, reporting unused files, unused exports, unused types, and unused dependencies as separate categories. Each category is its own routing decision: a single dead export is usually a PR; a cluster of unused types or files is usually an umbrella issue. Configuration lives in `knip.json` (entry points, ignore patterns, `ignoreExportsUsedInFile` for legitimate public type surface used through inference). If knip flags something that's intentional public surface, add it to the allowlist rather than carrying noise round-to-round.
5. **Missing test files** — `find` the `.ts` files under `config.paths.source` and the `*.test.ts` under `config.paths.tests`, diff the mirrored paths. Ignore type-only files, declarations, barrels.
6. **DRY violations** — read the larger files (top 10 by line count) and look for repeated blocks. This is the judgment-heavy step; don't force findings if nothing obvious surfaces.
7. **Weak abstractions** — same reading pass; note interfaces over 15 members, classes with mixed responsibilities.
8. **Circular / improper typing / other** — opportunistic.

**Always (any language):**

- **Repo-invariant drift** — cross-reference recent additions against the rules in `config.guidelines.invariants`. This is the highest-value category because CI doesn't catch any of it.
