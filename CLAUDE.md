# pacekeeper — instructions for Claude Code

Public, international repository: code, comments, README and this file in English. Commit
messages and tags are written in Italian — that is the convention the history already follows.

## A version lives in three places, and they move together

Every release changes **all three**, in the same commit and the same push:

| Where | What |
|---|---|
| `install.sh` | `VERSION="x.y.z"` |
| `README.md` | the two `curl … /pacekeeper/vx.y.z/install.sh` lines (Install and Update) |
| git | the annotated tag `vx.y.z` on that commit |

**Why the README cannot lag.** `install.sh` fetches its own files from the tag named by its
`VERSION` (`PACEKEEPER_REF="${PACEKEEPER_REF:-v${VERSION}}"`), and the README tells people which
tag to `curl`. A README pointing at an older tag hands out the previous release; a README pointing
at a tag that does not exist hands out a 404. Both have happened.

**Why the tag and the commit travel in one push.** `git push origin main vx.y.z` — never the branch
first and the tag later. Between the two pushes `main` carries an `install.sh` whose `VERSION`
names a tag GitHub does not have yet, and anyone running the installer in that window gets nothing.

**Before bumping, grep for the old number:** `grep -rn "1\.3\.3" README.md install.sh` — the README
has carried the version in two places since 1.3.2, and a bump that updates one of them passes the
version test (`tests/run.sh`, section "The version the README sends people to") only when both
match `install.sh`. Run the suite after the bump; that test is the guard.

## The README shows real output, not typed examples

The status-line screenshots in the README are produced by `statusline.sh` from a made-up payload
(the README says so under the first block). When a change alters what the line prints — a new
bracket, a renamed phase, a different figure for the same input — regenerate the screenshot from
the script and paste what it printed. A hand-edited example drifts: `today still 8.1%` sat in the
README for two weeks next to figures that made it `0.9%`.

## Two characters that do not survive an editor

- **Nerd Font glyphs** (`repo_icon`, `branch_icon`, U+F09B / U+F418) are private-use characters:
  invisible in a diff, invisible in a review, and silently dropped by editors that normalise what
  they cannot render. Insert them as explicit bytes (`perl -pi -e 's/…/"\xef\x82\x9b"/'`), and
  keep the byte-level test that guards them (`G1`/`G2` in `tests/run.sh`).
- **No apostrophes inside the awk programs.** They live between single quotes; a `day's` in a
  comment ends the program and every render fails with output on stderr.
