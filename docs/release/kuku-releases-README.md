# Kuku H4 Release Artifacts

This repository contains release artifacts only. Kuku source and the release tooling live in `horizonthinking/kb-app`.

Published GitHub releases are immutable. Nothing beneath a published tag is changed or deleted. A correction is released under the next unused `<upstream>-h4.<n+1>` version through the reviewed corrective cycle.

Each release uses tag `kuku-v<release>` and has exactly two assets:

- `Kuku-<release>.dmg`, the signed, notarized, and stapled application image.
- `Kuku-<release>.manifest.json`, the authoritative immutable provenance for the artifact.

The only release and cask writer is `scripts/h4/release_h4.sh` in `horizonthinking/kb-app`, with these four operations:

```text
release_h4.sh <version>
release_h4.sh install <release> <host>
release_h4.sh withdraw <release>
release_h4.sh cleanup <release>
```

The overseer-run Wave 3b procedure is the only writer of this README and the `audit/kuku-*` tags. It merges the audited feature branches, updates this file transactionally, installs the audit-tag rulesets, creates each audit tag once, and records the proof. Any new build number follows the corrective cycle and repeats that review and promotion procedure.
