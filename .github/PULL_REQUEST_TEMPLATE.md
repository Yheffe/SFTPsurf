## What changed

<!-- A sentence or two. What is different for the user? -->

## Why

<!-- The problem this solves. Link an issue if there is one. -->

## How it was verified

<!--
The commands you ran and what they printed. `./Scripts/test.sh` is the baseline;
mention anything else you did, such as testing against a particular server.
-->

## Checklist

- [ ] `./Scripts/test.sh` passes
- [ ] `swift build -c release` completes with no warnings
- [ ] Added or updated a test covering the change (for bug fixes, one that fails
      without it)
- [ ] Updated `CHANGELOG.md` under `Unreleased` if the change is user-visible
- [ ] Updated the README or in-code documentation if behaviour changed
- [ ] No new third-party runtime dependencies (or discussed in an issue first)

## Notes for reviewers

<!-- Anything you are unsure about, or deliberately left out of scope. -->
