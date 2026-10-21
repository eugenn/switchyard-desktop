# Releases and source provenance

## Two repositories

NVIDIA-NeMo/Switchyard is upstream. eugenn/Switchyard maintains the core changes
used by this app. eugenn/switchyard-desktop owns one native application and imports
core sources into `vendor/switchyard`. Each app release fixes an exact core
snapshot; the app and core do not need matching version numbers.

`vendor/switchyard-source.json` schema 2 records:

| Field | Meaning |
| --- | --- |
| `repository` | Public HTTPS URL of the maintained core fork |
| `commit` | Core checkout HEAD at import time; a base only for dirty snapshots |
| `upstream_repository` | NVIDIA upstream URL |
| `upstream_commit` | Merge base of that HEAD and the fetched upstream ref |
| `includes_tracked_worktree_changes` | Whether tracked working-tree/index changes were present |
| `files` | SHA-256 of every imported file |

The importer recognizes the existing `origin` = NVIDIA / `fork` = eugenn setup
and the conventional `upstream` = NVIDIA / `origin` = eugenn setup. It does not
rename remotes or fetch implicitly. Fetch upstream intentionally before syncing;
`--upstream-ref` can select a different fetched upstream ref. The recorded merge
base is the integrated upstream baseline, not necessarily upstream's latest tip.

Snapshots exclude `.agents`, `.claude`, `.github` and `.hooks`; untracked files
are not copied. A clean import is also compared with raw Git blobs, so local
filters or Git archive attributes cannot silently change its contents.

## Development and public release gates

`--allow-dirty` is for local development. Its flag stays true until a new clean
import; committing desktop alone cannot make a dirty core snapshot releasable.
The current imported snapshot is intentionally dirty and cannot be released.

```sh
# Offline integrity check; development snapshots are allowed.
python3 scripts/update-switchyard.py --verify

# Offline release metadata/integrity gate.
python3 scripts/update-switchyard.py --verify --release

# Public release gate: also fetch and compare the recorded core commit.
python3 scripts/update-switchyard.py --verify --release --check-published
```

Public packaging and final release verification run the third check. The fetch
uses a temporary repository and disables interactive credential prompts. Release
verification also checks the manifest embedded in the app against the checkout.
Run it from the matching desktop release sources. A missing, dirty, legacy or
mismatched manifest fails; an unavailable or mismatched published core commit
also fails. An optimized Swift `release` build with an ad-hoc signature remains
a development build and is allowed to use a dirty snapshot.

## Maintainer release sequence

1. Review and test core changes in the separate core checkout. Preserve NVIDIA's
   notices and add change notices to modified upstream files there. Commit and
   publish the core changes to the maintained fork when approved.
2. Import the clean core checkout with `python3 scripts/update-switchyard.py`.
   Review snapshot and manifest together. Run the published-source gate above.
3. Run desktop CI, build the complete development app, and exercise bundle smoke
   tests. Validate sign-in, a real request, Stop and crash recovery manually in a
   dedicated test account. Validate each architecture you intend to distribute.
4. Update `Resources/AppVersion.env`. Review and commit desktop changes, including
   the snapshot and manifest, when approved. Create an immutable `vX.Y.Z` app tag.
5. Build on the tagged checkout using `scripts/create-release-dmg.sh`, with
   `SWITCHYARD_DESKTOP_SIGNING_IDENTITY` and
   `SWITCHYARD_DESKTOP_NOTARY_PROFILE` configured outside the repository. This
   signs, notarizes, staples and verifies the app and DMG. It does not upload a
   GitHub release.
6. Publish the verified DMG and SHA-256 checksum with release notes linking the
   desktop tag and full core commit. List tested architectures and known limits.

Never move a released tag, build bundled helpers from PATH/the sibling checkout,
or install Python packages at app startup. Builds use checked-in Cargo and Python
locks. License texts for the app, core and dependencies are included in the bundle.
Review those texts when changing dependencies; a root Apache license does not
relicense third-party components.
