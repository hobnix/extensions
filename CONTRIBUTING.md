# Writing a package

1. One folder per package under `extensions/<name>/` with a `package.toml`:
   `name` (= folder), `version` (semver), `kind = "extension"`, `title`, `title_de`, `requires_core = ">=1"` (the API level of the core
   helpers it uses), `audience = "generic"` (or `"personal"`: hidden unless asked for).
2. `capability.toml` and `commands.tsv` describe the commands (`hs ext <name> <command>`), the web reads and the page; scripts are referenced as `@/file`.
3. Raise `version` in `package.toml` AND in `index.toml` (a patch for a fix, a minor for a feature, a major when a person has to act).
4. `python3 <core>/scripts/pkg.py validate` and `repo-check .` must pass (CI runs them against the core).
5. A release is a signed tag `vX.Y.Z` on the commit with the new index.
