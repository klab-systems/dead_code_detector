# Changelog

All notable changes to this project will be documented in this file.

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
