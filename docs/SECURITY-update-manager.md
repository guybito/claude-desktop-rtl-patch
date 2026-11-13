# Update manager: security design

Claude Desktop's built-in updater (MSIX build) freezes the app after it downloads an
update. The update manager replaces it and re-applies the RTL patch after every
update without a UAC prompt. This document lists what runs with which rights and why
none of it can be steered by a process running as the signed-in user.

## Pieces and rights

| Piece | Runs as | Input it accepts |
|---|---|---|
| `watcher.ps1` (task `ClaudeRtlPatchWatcher`) | signed-in user, **not elevated** | release feed, Claude processes, transcripts, the prompt's answer |
| `update-prompt.ps1` | signed-in user | the user's click |
| `repair.ps1` (task `ClaudeRtlPatchRepair`) | **SYSTEM** | **none** |
| `update.ps1` (shortcut) | user, then elevated through one UAC prompt | none (`-Refresh -Force` is fixed) |

The only elevated code is `repair.ps1`. Everything that reads network or user data
runs unelevated, so tampering with it gains nothing.

## What the elevated runner relies on

1. **Code only from an admin-only folder.** `C:\ProgramData\ClaudeRtlPatch` is owned by
   Administrators, inherits nothing and gives Users read-only access. `repair.ps1`
   checks this before doing anything and refuses otherwise. Nothing runs from `%TEMP%`.
2. **Signature right before running.** The local `patch-local.ps1` is verified against
   the pinned public key every time, and the runnable copy is written next to it.
3. **No input.** The task has a fixed action and no arguments. Any user process may
   start it (read + execute on the task's security descriptor), but not change it.
   Starting it only re-patches a Claude that is not patched yet; otherwise it exits
   without closing anything.
4. **Clean environment.** The task runs as SYSTEM, so the user's environment
   (`HKCU\Environment`, where per-user variables live) never reaches it. `repair.ps1`
   also rebuilds `PATH`, `PSModulePath`, `TEMP` and drops `NODE_OPTIONS` and similar
   variables before any cmdlet runs. The UAC path (`update.ps1`) does inherit the
   user's environment, like any program the user elevates; that path asks for consent.
5. **Node from Program Files only**, and no `npx`/npm download in silent mode.
6. **Rollback protection.** `-Refresh` refuses a downloaded `patch.ps1` whose
   `$script:PatchBuild` is lower than the local copy, even if it is signed.
7. **Claude download.** The watcher accepts only `https://downloads.claude.ai/...msix`
   for exactly the version the feed names, and Windows checks the package's Anthropic
   signature and package family before installing it.

## What stays outside the code

- **The signing key.** Signatures protect only while the private key is not on this
  PC. Keep `.claude-rtl-signing.key` on removable media or in a password manager and
  plug it in only to sign a release.
- **The one-time install** must be run from an elevated console the user opened
  (`tools/install-update-manager.ps1`); it verifies `patch.ps1` before running it from
  the admin-only folder.

## Removing it

Menu option 5 ("Disable Auto Re-Patch") removes both tasks and the
`disableAutoUpdates` policy, which hands updates back to Claude's own updater.
