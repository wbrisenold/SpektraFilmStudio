# Picker crash repair

The failed system panel stalled before selection while macOS resolved recent-folder bookmarks on a nonresponding volume. SpektraFilm now uses its own asynchronous browser for every open/save action. It does not reset macOS preferences, unmount drives, discard projects, or depend on the failing open/save XPC service.

Use the sidebar or type a folder/file path and press Go. Double-click folders (or use their arrow) to enter them. Command/Shift selection supports multiple photos. Show hidden files exposes SSH keys. Folder/save modes support creating folders. Existing save destinations require overwrite confirmation.

## Verification

Run `bash scripts/qa_10_passes.sh` and `bash scripts/build_app.sh`. Then launch the packaged app through Launch Services:

```sh
open -n -W --stdout /tmp/spektra-picker.log --stderr /tmp/spektra-picker.log dist/SpektraFilmStudio.app --args --picker-smoke-test
```

Require exit 0 and `PICKER_SMOKE_PASS`. This exercises visible windows, model entry points, nested-sheet selection, cancellation/reopen, duplicate guarding, slow I/O recovery, saving, project decoding with missing media and malformed-project preservation. It isolates recovery/recent-project writes. The tests use temporary fixtures, not the user's photos.

`Info.plist` → `SpektraSourceCommit` and `dist/build-info.txt` identify the actual build. A `-dirty` suffix means uncommitted sources. Rebuild after committing to package an artifact with the clean commit identity.

## Recovering a partially applied repair

The accompanying repair bundle contains reviewed base/intermediate states and target files. Run `python3 apply.py --check REPO` before `python3 apply.py REPO`. The same applicator is maintained in `scripts/apply_picker_repair.py` (pass `--bundle BUNDLE`). It performs no Git reset, staging, commit, fetch, or push. Unknown overlapping edits abort the entire preflight. Nonoverlapping edits and unrelated files are preserved; repeated application makes no changes. Backups are placed beside the checkout.

Do not reuse the older exact-source PATCH6 zip: it rejects an already-partially-repaired checkout by design.
