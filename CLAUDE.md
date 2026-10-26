# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb, and set of GitHub Actions, for SonarQube. It installs a checksum-verified SonarScanner CLI (SonarSource's Linux package with its own Java runtime, so cimg/base works), checks a project's `sonar-project.properties`, works out branch and pull request analysis from CircleCI's or GitHub Actions' environment, runs `sonar-scanner`, and exports the analysis' issues as SARIF for GitHub code scanning: `install`, `setup`, `scan`, `export_sarif` and `upload_sarif`. It is not affiliated with SonarSource.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh tests/*.sh

# Tests (offline; commands_test.sh needs python3, jq, curl and git, install_test.sh needs zip and unzip)
for t in tests/*_test.sh; do bash "$t" || break; done

# Run one command's script with its YAML defaults (what test-deploy.yml uses for steps that must fail)
bash tests/run_command.sh setup working_dir=tests/fixtures/project branch_analysis=false

# Print checksum table entries for a new scanner release (needs gpg)
./src/scripts/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/` - `install`, `setup`, `scan`, `export_sarif`, `upload_sarif`, one script each in `scripts/`
- `scripts/lib/sonarqube.sh` - Helpers shared by the command scripts, passed to each step as `SCRIPT_SONARQUBE_LIB: << include(scripts/lib/sonarqube.sh) >>` and `eval`ed after a check that it is set. Only defines functions; no `set` line.
- `examples/` - Usage examples, pinned to the orb's current version
- `../actions/<command>/action.yml` - The GitHub Action for each command (see below)

The commands hand each other environment variables through `BASH_ENV` (or `GITHUB_ENV`, through `actions/run_script.sh`): `setup` exports `SONARQUBE_ORB_PROPERTIES` (one `key=value` per line), which `scan` passes as `-D`; `scan` exports `SONARQUBE_ORB_REPORT_TASK` (the scanner's `report-task.txt`), `dashboard_url_env_var` and `task_id_env_var`, which `export_sarif` reads; `export_sarif` exports `sarif_file_env_var` (default `SONAR_SARIF_FILE`), which `upload_sarif` reads. `tests/wiring_test.sh` checks these names agree. Don't name a variable `SONAR_SCANNER_*`: the scanner turns every such environment variable into a `sonar.scanner.*` property.

### Install (`scripts/install.sh`, `install_hash.sh`)

`install.sh` follows the layout every juburr orb's install.sh shares: a tool definition, the shared install logic (byte-identical across the orbs; never edit it here alone), and the `sha512sums` table keyed `"<version>/<arch>"`. `tests/install_test.sh` is the shared install contract, with this orb's tool fixture; `scripts/cache_key.sh` is shared too. The tool definition:

- **Versions and build numbers.** SonarSource numbers releases with a build number (8.2.0.6438), but the shared logic accepts only two or three numbers. So the table and the `version` parameter use 8.2.0, and `sq_scanner_builds` supplies the build number. A full four-part version is split before the shared logic reads it, and its build must match the list's. An unlisted release (with `known_versions`) needs the full version. `SQ_SCANNER_BUILD` in the environment gives the build to `install_hash.sh`, and to the contract test's stand-in versions.
- **Downloads.** It fetches the Linux package with its own Java runtime, `sonar-scanner-cli-<version>.<build>-linux-<x64|aarch64>.zip`. It tries binaries.sonarsource.com, then Maven Central, which publishes the same files. A `download_base_url` mirror replaces both, and is tried with SonarSource's paths, then Maven's.
- **The installation.** The table holds the zip's SHA-512. `tool_install` unpacks it (with unzip, or bsdtar) into a staging directory beside `install_path`, which becomes the installation's root, with its `bin` on the `PATH`. It checks the layout (`bin/sonar-scanner`, `lib/sonar-scanner-cli-<full>.jar`, `jre/bin/java`), writes a `.sonarqube-orb` marker, smoke-tests `sonar-scanner --version`, and only then swaps it in. `install_path` must be missing, hold no files, or be an earlier install, which the marker identifies.

`install_hash.sh -v <version>` hashes both architectures. Its `verify_upstream` requires three things of each package:

1. SonarSource's `.sha256` must match.
2. Maven Central's `.sha256` must match. Maven Central never replaces a published file.
3. The `.asc` signature must verify with SonarSource's key, primary fingerprint `679F1EE92B19609DE816FDE81DB198F93525EC1A`, fetched from keys.openpgp.org and keyserver.ubuntu.com, which keep every subkey.

A signature from a revoked subkey is reported, and the entry then rests on the two checksums. SonarSource revoked the subkey `2161D72E7DCD4258`, which signed 7.0.0 to 8.0.0, on 2025-11-30 with reason "Key has been compromised". gpg still prints "Good signature" for those (EXPKEYSIG plus KEYREVOKED), so never accept a signature on gpg's word alone.

To add a release:

1. Add its build number to `sq_scanner_builds`.
2. Run `install_hash.sh -v`.
3. Paste the entries into the table, newest first.
4. Move the `version` default in `install.yml` when it is the newest. `tests/wiring_test.sh` checks the default is the newest in the table.

The table covers 7.0.0 to 8.2.0.

### Command scripts (`src/scripts/`)

- **`setup.sh`** reads the properties file with `sq_properties_read`, an awk reader with `java.util.Properties` semantics: comments, `=`, `:` or white space after the key, continued lines and escapes. Like the scanner, it then resolves `${env.NAME}` and `${KEY}` placeholders (`sq_resolve`). A value with a placeholder it can't resolve isn't checked; that is left to the scanner. It fails on:
  - a missing file (unless `require_properties_file` is false and `project_key` is set);
  - a missing or invalid project key;
  - a `sonar.sources` or `sonar.tests` path that doesn't exist (relative to `sonar.projectBaseDir`).

  It warns about:
  - credentials in the file;
  - branch or pull request properties in the file;
  - SonarQube Cloud without `sonar.organization`;
  - no server URL;
  - a shallow checkout;
  - a pull request base the checkout lacks.

  `sq_ci_context` reads the branch, pull request, tag, commit and repository from CircleCI (`CIRCLE_PULL_REQUEST`/`CIRCLE_PR_NUMBER`, `CIRCLE_BRANCH`, `CIRCLE_TAG`) or GitHub Actions (`GITHUB_EVENT_NAME`, `GITHUB_REF`, `GITHUB_HEAD_REF`/`GITHUB_BASE_REF`, the event file). CircleCI doesn't say a pull request's base, so `sonar.pullrequest.base` is left out and SonarQube uses the main branch.

  `branch_analysis auto` sends branch and pull request properties:
  - always to SonarQube Cloud (by host);
  - to a server whose `api/navigation/global` `edition` isn't `community`. That endpoint needs the token on SonarQube Server, so an http:// server (other than loopback) is never asked it.
  - Without an edition, `api/server/version` separates Community Build (major 24 to 99) from SonarQube Server (2025.x and on, or 10.x and before), as the scanner itself does. It needs no token, so it is asked without one, over http too. `sq_api` allows http when it sends no token.
  - An unknown edition gets them, with a warning.

  `branch_analysis false` only leaves them out. SonarQube Server Developer Edition and above detect a branch or pull request on GitHub Actions by themselves, and no scanner setting reliably stops that: `sonar.ci.autoconfig.disabled` only empties the scanner's CI configuration (its revision and DevOps platform). So the descriptions don't promise a main-branch analysis.

  The properties file is never changed.
- **`scan.sh`** builds the scanner's arguments in this order (a later `-D` wins):
  1. `host_url`;
  2. setup's properties;
  3. `properties` (one `key=value` per line, `#` comments);
  4. `skip_jre_provisioning`, which sets `sonar.scanner.skipJreProvisioning` and `sonar.scanner.javaExePath` to the install's `jre/bin/java`. The embedded-JRE packages still download a JRE from the server otherwise, and CLI 8.2 no longer exports `JAVA_HOME` to its own runtime.
  5. the quality gate (`sonar.qualitygate.wait`/`.timeout`);
  6. `-Dsonar.scanner.metadataFilePath=<pwd>/.scannerwork/report-task.txt`, which must be absolute;
  7. `extra_args`.

  `sonar.token`, `sonar.login`, `sonar.password` and `sonar.scanner.metadataFilePath` are refused in `properties` and `extra_args`. The token and `java_opts` (as `SONAR_SCANNER_OPTS` and `SONAR_SCANNER_JAVA_OPTS`) are exported in a subshell that `exec`s the scanner, never on a command line, not even `env`'s.

  After the scanner runs, the report is exported even when the scan fails. The base directory the scanner logged (`INFO  Base dir: /path`), which the properties file, `properties`, `extra_args` and `project.settings` can all set, goes with the task ID into `sonarqube-orb.properties` beside the report, for `export_sarif`. The log tells apart a failed gate (`QUALITY GATE STATUS: FAILED`), the gate's timeout (`Quality Gate check timeout exceeded`) and Community Build refusing a branch (`Developer Edition or above is required`). The scanner exits 3 for engine failures, 1 for bootstrap failures and 2 for user errors.
- **`export_sarif.sh`** reads `report-task.txt` (raw `key=value` lines; split at the first `=`). It builds API URLs from `host_url`, else `SONAR_HOST_URL`, else the report's `serverUrl`, which is the server's own idea of its URL. It then:
  1. polls `api/ce/task?id=` until SUCCESS. That needs Execute Analysis or Administer, not just Browse, so analysis tokens fail there.
  2. takes `componentKey`, `branch` and `pullRequest` from the task (absent for the main branch);
  3. pages through `api/issues/search` with `componentKeys` (SonarQube Cloud rejects `components`), `branch`/`pullRequest`, `resolved=false`, `additionalFields=rules`, `ps=500`, up to page 20, since `p*ps` must stay at or under 10,000. Cloud's `paging.total` stops at 10,000, so that many may be more. 503 (issue indexing) is retried.

  jq turns the issues into one SARIF run:
  - **Level** is the highest of the issue's `impacts` severities, else its legacy `severity`. Both are always returned, whatever the server's mode.
  - **Region:** `textRange` lines are 1-based and offsets 0-based, so `startColumn = startOffset + 1`.
  - **Paths:** URIs are prefixed with `git rev-parse --show-prefix` of the project's base directory: the one `scan` recorded beside the report, when its task ID is the report's; else the `sonar.projectBaseDir` of its properties file (setup's `project.settings`, or `sonar-project.properties`); else `working_dir`. Each path segment is percent-encoded.
  - **Fingerprint:** GitHub matches alerts only by `partialFingerprints.primaryLocationLineHash`, and doesn't compute it for API uploads. It is `<rule>:<issue hash or key>:<n>`, so it is stable between analyses and between a branch and its pull requests.
  - **`security-severity`** is a string, set on rules with security issues. Those rules also get the `security` tag, without which GitHub ignores it.
  - **`automationDetails.id`** is `<category>/<project>/`.
  - **Left out:** issues with no file. GitHub needs a location.
- **`upload_sarif.sh`** gzips and base64-encodes the file (10 MB gzipped at most), and posts `{commit_sha, ref, sarif, tool_name}` to `POST /repos/{owner}/{repo}/code-scanning/sarifs`. It then polls `GET .../sarifs/{id}` for `processing_status`.
  - **Defaults:** the commit and ref come from GitHub Actions (`GITHUB_SHA`, `GITHUB_REF`) or CircleCI (`CIRCLE_SHA1`, and `refs/pull/<n>/head`, `refs/heads/<branch>` or `refs/tags/<tag>`).
  - **`pull_request_target`:** on that event `GITHUB_REF` and `GITHUB_SHA` are the base branch's, so a pull request's results go to `refs/pull/<n>/head` and `.pull_request.head.sha` from the event file instead. Otherwise the partial results would replace the base branch's alerts.
  - **403 and 404** explain what code scanning needs: public repositories on github.com, or GitHub Code Security / Advanced Security for private ones and GHES.
  - **The API's base** is `api_url`, then `GITHUB_API_URL`, then `https://api.github.com`. For GHES it is `https://HOST/api/v3`.

### Shared helpers (`scripts/lib/sonarqube.sh`)

- **Values and words.**
  - `sq_subst` expands environment variables by piping the value to `circleci env subst` on stdin, and uses the value as is without the CLI (local runs and GitHub Actions).
  - `sq_words` splits `extra_args` with `split_shell_words`, the parser container-ops-orb, oras-orb and the other juburr orbs use, refusing `$(...)`, backticks and shell operators outside quotes.
  - `sq_bool`, `sq_match` (`[[ =~ ]]` in the C locale), `sq_env_var_name`, `sq_export` (`printf 'export %s=%q\n'` to `$BASH_ENV`).
- **Properties.** `sq_properties_read FILE` sets `SQ_PROPS`. Callers `declare -A SQ_PROPS=()` first, since bash 4.0 and 4.1 have no `declare -g`. `sq_secret_key` and `sq_print_property` hide credentials.
- **The server and the token.**
  - `sq_host_url` resolves the server and refuses credentials in it.
  - `sq_cloud` and `sq_loopback` classify a URL.
  - `sq_token NAME` reads the token, with xtrace off.
- **API calls.**
  - `sq_curl_init` sets up curl: `--fail-with-body` when curl has it, else `--fail`.
  - `sq_auth_header FILE NAME VALUE` writes a header file (`-H @FILE`, so no token on a command line).
  - `sq_api URL OUT` calls an API and prints the HTTP status. It uses `--proto =https`, or http too for a loopback host, so a token never crosses a network in clear.
- **CI.** `sq_ci_context` reads CircleCI's or GitHub Actions' environment.

### GitHub Actions (`actions/`)

Every command has a composite action of the same name in `actions/<command>/action.yml`, with inputs identical to the command's parameters (names and defaults). Each step passes inputs to the orb's script as `PARAM_*` environment variables, as the command does, and runs it with `bash "${GITHUB_ACTION_PATH}/../run_script.sh" SCRIPT SCRIPT_SONARQUBE_LIB=<lib>`, with `working-directory: ${{ inputs.working_dir }}`. Inputs never appear inside a `run:` script.

- **Artifacts.** `export_sarif` names its artifact `sonarqube-reports-<report_name>-<random>`, and uploads it with `actions/upload-artifact` under `if: always()` and `store_artifacts`.
- **Caching.** `install` restores and saves `actions/cache` with the command's key.
- **`when`** has no effect on GitHub Actions; users give the step `if: always()`.
- **A failed step exports nothing.** `run_script.sh` passes on nothing from a script that fails, so after a failed quality gate `export_sarif` falls back to `.scannerwork/report-task.txt` in its `working_dir`.
- **Pins.** Every `uses:` is pinned to a commit SHA, with its version in a comment.

`actions/run_script.sh` and `tests/actions_test.sh` are identical in every juburr orb that ships actions; never edit them here alone. Keep the actions in sync with the command YAML by hand or with an equivalent generator, and quote any default a YAML 1.1 reader would take for a boolean or number. `tests/actions_test.sh` checks all of this.

### CI Pipeline

- **`.circleci/config.yml`** is the setup workflow:
  - `test-install`: `tests/install_test.sh`, the install contract against stand-in zips;
  - `test-env-subst`: the env subst and shell conventions tests;
  - `test-commands`: `tests/commands_test.sh` and `tests/wiring_test.sh`, on `cimg/python`;
  - `test-actions`;
  - orb-tools lint, pack and review (`orb_name: sonarqube`), and shellcheck.
- **`.circleci/test-deploy.yml`** runs the real tools:
  - `install-test`: on cimg/base, which has no Java; the default and the oldest listed release, and the cache.
  - `checksum-test`: an unlisted release fails closed; `known_versions` with a full version installs it; a local HTTPS mirror in Maven's layout serves the real release, then a tampered one.
  - `arm64-test`.
  - `scan-test`: a matrix of scanner 7.0.0 and 8.2.0 by Community Build 25.9 and 26.10, in Docker on a machine executor. It runs every command against `tests/fixtures/project`, then a failing quality gate and a refused branch through `tests/run_command.sh`.
  - `skip-jre-test`.

  Publishing runs on `v*` tags.
- **`.github/workflows/actions.yml`** runs the actions:
  - `offline-tests`;
  - `install` on amd64 and arm64, then `install-from-cache` with the download hosts blocked in `/etc/hosts`;
  - `scan`: the same matrix, with SonarQube as a service container, and the SARIF file checked against the OASIS schema (pinned by SHA-256);
  - `upload-sarif`: only on `workflow_dispatch`, so the tests leave no code scanning alerts behind.
- **`tests/sonarqube_server.sh`** prepares a fresh server:
  - it waits for `api/system/status` UP;
  - it changes the admin password (12 characters with upper and lower case, a digit and a symbol), since a fresh server answers with it changed;
  - it generates a user token;
  - it makes a quality gate that fails every analysis (`ncloc GT 0`).

`tests/commands_test.sh` runs the scripts against a stand-in `sonar-scanner` (in a tree with `jre/bin/java`) and `tests/fake_server.py`, a stand-in for the SonarQube Web API and GitHub's REST API on 127.0.0.1, which the scripts reach with the real curl. Routes give responses in turn, and every request is logged with its query, Authorization header and body.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as `sq_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace; `sq_token` and `upload_sarif.sh` run `set +o xtrace` before reading a token, with a one-line comment.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them (`tests/run_command.sh` sets them from the YAML).
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_SONARQUBE_LIB}"`). Secrets never go on a command line, and curl that sends credentials or fetches trusted content uses `--fail` (or `--fail-with-body`) and `--proto '=https'` (http only to a loopback host).
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script (a second `trap ... EXIT` replaces the first).
- The scripts must work with jq 1.6: never `jq -e` on a tool's output, and write numbers that must look a certain way (such as `security-severity`) as strings, since jq 1.6 and 1.7 print `8.0` differently.

## Naming

Command names say what they do (`install`, `setup`, `scan`, `export_sarif`, `upload_sarif`). Parameters that map onto one scanner property or API field take its name in snake_case (`branch_name` for `sonar.branch.name`, `pull_request_key`, `quality_gate_wait`, `skip_jre_provisioning`, `commit_sha`, `ref`). Plumbing matches the other juburr orbs: `working_dir`, `extra_args`, `output_dir`, `report_name`, `store_artifacts`; credentials are `env_var_name` parameters (`token`, `github_token`); variables a command writes are `<thing>_env_var`.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh tests/*.sh`
- Run every `tests/*_test.sh`, also with bash 4.0 and 4.3 first on the `PATH`, and with jq 1.6
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml`, and validate `.circleci/test-deploy.yml` with the packed orb spliced in under `orbs.sonarqube-orb`
- For changes to a command, also run it against a real SonarQube Community Build container, as `test-deploy.yml` does
