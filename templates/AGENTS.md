# AGENTS.md: rules for every coding agent working in this repository

You may be one of several agents working in parallel, each in its own git worktree and branch.
A Tech Lead (Claude Code) assigns one task per prompt and reviews everything against git.

1. Do exactly the task in your prompt. Nothing else, no "while I'm here" changes.
2. Work only in the workspace named in your prompt and commit only on its `task/<id>` branch.
   Never switch branches, never touch other worktrees, never push.
3. Modify only the files your prompt allows. Put anything else you think is needed under DEVIATIONS.
4. Locked test files are copied byte-for-byte and never edited.
5. Tests first, then code. Run the commands your prompt lists and paste their real output.
6. Every command needs a timeout. Never leave a process hanging.
7. Report honestly: a target is "met" only if the number satisfies it; "DEVIATIONS: none" only if true;
   the commit SHA you report must exist on your branch.
8. Finish with the HANDOFF file in the last commit and no uncommitted files. Then stop.
9. Never print, store or commit secrets (tokens, passwords, URLs with credentials).
