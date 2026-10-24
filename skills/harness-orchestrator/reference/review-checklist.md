# Review checklist (run for every HANDOFF)

Automatic, with `verify-handoff.ps1`:
- [ ] HANDOFF committed on `task/<id>`, in the last commit
- [ ] every SHA cited exists and is on the branch (`sha-not-found`, `sha-not-on-branch`)
- [ ] FILES CHANGED equals `git diff --name-only <base>...task/<id>`
- [ ] no file outside the allowed globs, none matching the forbidden globs
- [ ] `DEVIATIONS: none` is consistent with the diff
- [ ] no uncommitted work left in the worktree

By hand (the script cannot judge these):
- [ ] Read the whole diff. Look for scope creep, deleted tests, weakened assertions, `skip`/`xfail`, broad `except`.
- [ ] Locked tests byte-identical: `git diff <base> task/<id> -- <locked files>` is empty.
- [ ] Re-run the task tests, the full suite, the linter and the build yourself, in the worktree. Compare with the HANDOFF.
- [ ] Every "met / pass / done" claim: find the raw number and check it against the target. A miss reported as
      "met" is a FIX, even if the code is fine.
- [ ] Versions and environment facts in the report (library, browser, driver versions) match what is installed.
- [ ] Scripts used for measurements are committed, and the numbers can be reproduced.
- [ ] No secrets, absolute personal paths or machine names in committed files.
- [ ] New dependencies only if the prompt allowed them.

Failures seen in real runs (why this list exists):
1. `DEVIATIONS: none` although the worker found that a library build lacked a class the plan relied on.
2. The commit SHA in the HANDOFF did not match `git log`, twice.
3. A wrong browser version was reported.
4. A measurement script was run but not committed.
5. Every performance target was marked "met" while the report's own table showed several misses.

Verdict format:
```
REVIEW <id>: GO | FIX
- [file:line] defect -> expected
```
