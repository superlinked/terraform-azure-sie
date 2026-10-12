# Contributing

Terraform module versions describe infrastructure changes, not SIE application
releases. Updating installation documentation for a SIE release does not require
a new module version. Keep module version constraints independent from the chart
or image version selected for an installation.

For documentation, examples, tests, or automation-only changes, use `docs:`,
`chore:`, `ci:`, `test:`, or `style:` in both the pull request title and every
branch commit. Do not add breaking-change markers, `Release-As:` footers, or
release commit overrides to these changes. CI checks these conventions because
Release Please directory exclusions cannot exclude individual root files such
as `README.md`.

Use normal Conventional Commits (`fix:`, `feat:`, or a breaking-change marker)
when changing the module itself. A change containing module code and
documentation is still eligible for a module release. Unknown paths are treated
as module payload, so new runtime or submodule files are not silently excluded.

Release Please continues to run on every push to `main`, including the merge of
a generated release pull request. Real module releases still update module
version references in the examples; do not hand-edit the release manifest or
changelog to create a documentation-only release.
