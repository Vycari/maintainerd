# Language-specific mechanics — audit-tests

The concrete greps and tool flags behind the category table. **Run only the block matching
`config.language`.** The table in SKILL.md decides what counts as a finding; this file is how to
find it in this language.

The smells above are language-agnostic. The exact detection commands and the framework names depend on `config.language`. Apply the equivalent for whichever language the config declares; read `config.guidelines.testing` for the conventions that are specific to this repo's runner.

## When `config.language` is `python`

Framework: pytest + `unittest.mock`. Treat `config.paths.tests` as the grep root.

- **Mocked collaborators / sessions:** `grep -rnE "(MagicMock|AsyncMock|Mock)\(" <tests>` and read for `patch("...")` / `patch.object(...)`. Cross-reference each against the "what may not be mocked" rule in `config.guidelines.testing` (e.g. mocking the DB session instead of the real test-DB fixture).
- **Weak assertions / broad raises:** `grep -rn "pytest.raises(Exception)\|pytest.raises(BaseException)" <tests>`; scan for assertion-free test bodies.
- **Flaky:** `grep -rn "time\.sleep\|asyncio\.sleep" <tests>`; scan for unfrozen `datetime.now()`/`date.today()`/`random` in result-asserting tests (the fix is `freezegun`/`freeze_time` or injecting the value).
- **Skip/xfail rot:** `grep -rn "@pytest.mark.skip\|@pytest.mark.xfail\|pytest.skip(" <tests>` — flag any without `reason=`, and any `xfail` that now passes (`--runxfail` reports XPASS).
- **Redundant framework boilerplate:** if `config.guidelines.testing` says the repo runs pytest-asyncio in `asyncio_mode = "auto"`, then `@pytest.mark.asyncio` is a no-op — `grep -rn "@pytest.mark.asyncio" <tests>` and remove. Don't assume auto-mode; confirm it in the guidelines first.
- **Parametrize:** the duplication target is `@pytest.mark.parametrize`.
- **Slow tests:** `<config.commands.test> --durations=25 -q`.
- **Coverage:** `config.commands.coverage` typically emits `coverage.json` (branch coverage on); read it for covered-lines-but-uncovered-branches.

## When `config.language` is `typescript`

Framework: the repo's test runner (Jest or Vitest — check `config.commands.test`). Apply the equivalent of each python check.

- **Mocked collaborators:** `grep -rnE "(jest|vi)\.(mock|fn|spyOn)\(" <tests>` and read each. Cross-reference against the "what may not be mocked" rule in `config.guidelines.testing`. Spying on / mocking a module you own that could run for real is the same smell as the python session-mock case.
- **Weak assertions / broad throws:** flag `expect(...).toThrow()` with no error matcher, and test bodies with **no `expect(...)`** at all. Tighten `toThrow()` to a specific error type/message.
- **Flaky:** `grep -rnE "setTimeout|new Promise\(.*setTimeout" <tests>` for real-time waits; unfrozen `Date.now()`/`Math.random()` in result-asserting tests. The fix is **fake timers** (`jest.useFakeTimers()` / `vi.useFakeTimers()` and `setSystemTime`) or injecting the value — the direct analog of freezing the clock.
- **Skip/only rot:** `grep -rnE "\.(skip|only|todo)\(|xit\(|xdescribe\(" <tests>`. A stray `.only` is a real smell — it silently disables every other test in the file; a `.skip`/`xit` without a comment reason is rot.
- **Redundant framework boilerplate:** per `config.guidelines.testing` — leftover `.only`, redundant `async` wrappers, etc.
- **Parametrize:** the duplication target is `it.each` / `test.each` / `describe.each`.
- **Golden-snapshot noise:** oversized or volatile `toMatchSnapshot()` / inline snapshots that re-bless on every change.
- **Slow tests:** the runner's slow-test reporting (Jest `--verbose` timings; Vitest's slow-test reporter).
- **Coverage:** `config.commands.coverage` typically emits `coverage-summary.json` / lcov; read it for uncovered branches in already-tested files.
