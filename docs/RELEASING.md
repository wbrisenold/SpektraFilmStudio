# Release procedure

1. Review local differences and preserve unrelated edits. Fetch GitHub main and reconcile without a destructive reset or force push.
2. Regenerate the source manifest, run source gates, build Intel x86_64, and run applicable native/transfer/model tests. Review actual screenshots.
3. Commit reviewed changes and push main normally. Repackage from the clean commit and verify the compiled SwiftPM product matches the tested product.
4. Check the exact commit in Info.plist and `dist/build-info.txt`, the ZIP digest, architecture and signature. Retain `dist/` locally.
5. For public distribution, use Developer ID signing and notarization/stapling with the owner’s credentials. Publishing a release or replacing existing tags/assets is a separate explicit action. Do not force-update a tag or overwrite release assets as a side effect of pushing main.

Current local artifacts are ad-hoc signed. Provider deployments, external account tests and notarization are not implied by source QA success. The validation report must state what actually ran and remaining limits. Earlier release automation notes are preserved in [Development history](DEVELOPMENT_HISTORY.md).
