# Changelog

All notable changes to this project will be documented in this file.

## Release 2.0.1 (2026-10-23)

**Bug fixes**

- Read type and function declarations as UTF-8 independently of the task process locale, preventing `unused_types`, `unused_functions`, and `full_audit` from failing on non-ASCII source comments under US-ASCII locales. Invalid UTF-8 encountered during discovery now raises an explicit error identifying the source file and line rather than returning a partial report.
- Added regression tests covering all five declaration styles under a US-ASCII default external encoding, including malformed source bytes.

## Release 2.0.0 (2026-10-20)

**Breaking changes**

- Updated the supported Puppet range from `>= 7.24 < 9.0.0` to `>= 8.0.0 < 10.0.0`. Puppet 7 is no longer supported; Puppet 9 is now included.
- Updated the operating system support declarations: removed CentOS, Scientific Linux, Debian, Oracle Linux 7, Red Hat Enterprise Linux 7, and Ubuntu 18.04/20.04. Declared support now covers Oracle Linux 8/9, Red Hat Enterprise Linux 8/9/10, Rocky Linux 8/9, AlmaLinux 8/9, and Ubuntu 22.04/24.04/26.04.
- Development dependencies now default to the authenticated Puppet Core gem repository for Bolt, Puppet, and Facter. Contributors using public gems can opt out with `bundle config set gemsource.public true`. The previous `GEM_SOURCE_PUPPETCORE` override is no longer used.

**Features**

- Made `targets` optional in the `dead_code_detector::full_audit` plan. When omitted, the plan discovers the Primary Server through PuppetDB using `inventory[certname] { facts.pe_status_check_role = "primary" }`. This requires a PuppetDB connection configured for Bolt. Discovery fails with an explicit error if no primary or multiple primaries are found; explicit targets remain supported.

**Maintenance and testing**

- Updated the module to PDK 4.0.1 and refreshed its template, gem dependencies, lint configuration, and Rake task loading, including compatibility updates for Ruby 4 and Puppet 9 development environments.
- Refactored the shared library to extract common environment validation and source scanning, consolidate function discovery, and split Hiera scanning and reporting into smaller methods while preserving task report formats and ordering.
- Resolved Ruby lint offenses, including using `$stdin` in all seven task entry points, passing a block directly to `to_set`, and correcting the brace-delimited defined-type regular expression.
- Added 22 unit tests covering function, template, file, type, and Hiera scanners, including invalid environment handling, report shapes, reference matching, key ordering, and YAML errors. Tests use temporary filesystem fixtures without live Puppet services.

**Documentation**

- Documented automatic Primary Server discovery and its PuppetDB configuration requirements in the README.
- Added explanatory comments to the unit tests describing fixture setup, expected results, and scanner behavior.

## Release 1.1.0 (2026-06-01)

**Features**

- Added `dead_code_detector::analyze_hieradata` task — static analysis task that audits hieradata from the control-repo environment layer. Reads the environment-level `hiera.yaml` to locate all declared data directories, then parses every YAML file found under those directories. For each top-level hiera key, reports how many hieradata files it appears in and which files contain it. Results are sorted from least popular (fewest files, default) to most popular via the `sort` parameter, making it easy to surface staleness candidates. Module-level hiera data is excluded. No Puppet Server or PuppetDB connection is required.
- Added `Deadwood::HieraScanner` to the shared `deadwood.rb` library. Handles `hiera.yaml` parsing (including per-hierarchy `datadir` overrides), recursive YAML file discovery, key frequency aggregation, and flexible sort ordering. File paths in results are reported relative to their data directory (e.g. `common.yaml`, `os/Debian.yaml`).
- Added `plan_summary` key to the `full_audit` plan return value. Appears between `meta` and the per-category detail keys, and mirrors the count information already printed to the event log — making the totals available programmatically without parsing the full result.
- Added `summary` key to every individual task's return value. Appears between `meta` and the result data in each task's output, providing at-a-glance counts without iterating the full arrays. Fields vary per task: `unused_classes`/`unused_functions`/etc. report unused and (where applicable) used counts; `analyze_hieradata` additionally reports `keys_in_single_file` (the count of keys appearing in exactly one data file — the strongest staleness signal) and `warning_count`.
- Integrated `analyze_hieradata` into the `full_audit` plan. The plan now runs six tasks (updated from five), with `analyze_hieradata` as step 6/6. The `hieradata` key is added to the plan return value, and `plan_summary` is extended with `hiera_keys_total` and `hiera_keys_single_file`. A `hiera_sort` parameter controls the key sort order within the plan.

**Documentation**

- Updated README to document `analyze_hieradata` task — added description bullet, parameter reference table (`environment`, `env_dir`, `sort`), and output format example.
- Updated README `full_audit` plan documentation — progress indicator updated to 6/6 steps, return value example updated to include `hieradata` key and expanded `plan_summary` fields (`hiera_keys_total`, `hiera_keys_single_file`), and `hiera_sort` added to the plan parameter reference table.
- Updated PE CLI and Bolt usage sections to include `analyze_hieradata` in the list of available individual tasks.
- Updated task count from six to seven in the module introduction.

## Release 1.0.0 (2026-04-22)

**Features**

- Added `dead_code_detector::full_audit` plan — runs all five unused-* tasks against the Primary Server in sequence and returns a single combined JSON report organised by category. Prints a live progress indicator and summary counts during the run.
- Added `dead_code_detector::unused_classes` task — identifies classes defined in an environment that have no catalog presence across active nodes in PuppetDB. Reports unused classes and any modules where every class is unused.
- Added `dead_code_detector::used_classes` task — ranks all classes applied across active nodes by node count (highest first). Supports a `top_n` parameter to limit results to the most-used classes.
- Added `dead_code_detector::unused_functions` task — static analysis of the environment's module directories. Discovers Puppet-language, modern Ruby API, and legacy Ruby API functions, then cross-references each against call sites in manifests, functions, templates, and library files. Includes a `warnings` key when legacy unnamespaced functions are detected.
- Added `dead_code_detector::unused_types` task — hybrid analysis combining static filesystem discovery with live PuppetDB resource catalog data. Detects Puppet-language defined types (`define` in `manifests/`) and native Ruby custom types (`Puppet::Type.newtype` in `lib/puppet/type/`) and reports them in separate result keys.
- Added `dead_code_detector::unused_templates` task — static analysis that discovers all EPP and ERB templates under module `templates/` directories and checks for their canonical `'<module>/<relative_path>'` reference string across the codebase.
- Added `dead_code_detector::unused_files` task — static analysis that discovers all static files under module `files/` directories and checks for their canonical `puppet:///modules/<mod>/<path>` URI across the codebase.
- Extracted all shared client, analyser, and scanner logic into `files/deadwood.rb` (`Deadwood::PuppetServerClient`, `PuppetdbClient`, `DeadCodeAnalyzer`, `UsageAnalyzer`, `FunctionScanner`, `TypeScanner`, `TemplateScanner`, `FileScanner`). All tasks require this single library with no duplication.
- All tasks are compatible with Puppet Enterprise (via PE Orchestrator or Puppet Bolt) and Puppet Core / OpenVox (via Puppet Bolt).

**Renamed tasks**

- `dead_code_detector::generate` renamed to `dead_code_detector::unused_classes`.
- `dead_code_detector::class_usage_report` renamed to `dead_code_detector::used_classes`.

**Documentation**

- Rewrote README to lead with the `full_audit` plan as the primary entry point, with individual tasks described as targeted alternatives.
- Added step-by-step PE Console instructions for running the plan and individual tasks.
- Added Puppet Bolt usage section covering Puppet Enterprise, Puppet Core, and OpenVox.
- Added full parameter reference tables, output format examples, and limitations for all tasks.

## Release 0.1.0

**Features**

- Initial release of `dead_code_detector`.
- Adds the `dead_code_detector::generate` task, which identifies unused Puppet classes and modules by querying the Puppet Server class API and cross-referencing against PuppetDB catalog data.
- Task must be run targeting the Puppet Primary Server, using the node's own SSL certificates for API authentication.
- Supports configurable parameters: `puppetserver_host`, `puppetdb_host`, `puppetserver_port`, `puppetdb_port`, `environment`, `stale_days`, `cert`, `key`, and `ca_cert`.
- Returns a JSON report with `unused_classes` and `unused_modules` keys.
- Supports Puppet Enterprise with PuppetDB via PE Orchestrator.

**Bugfixes**

**Known Issues**

- Detection is limited to classes and modules. Defined types, functions, facts, and other Puppet code constructs are not analysed.
- Analysis is scoped to a single environment per task run.
