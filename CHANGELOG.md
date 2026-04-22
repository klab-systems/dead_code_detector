# Changelog

All notable changes to this project will be documented in this file.

## Release 0.2.0 (unreleased)

**Features**

- Added `dead_code_detector::full_audit` Bolt plan — runs all five unused-* tasks against the Primary Server in sequence and returns a single combined JSON report organised by category, with a summary line count printed at the end of the run.
- Added `dead_code_detector::unused_files` task — purely static analysis task that discovers all files under module `files/` directories and checks for their canonical `puppet:///modules/<mod>/<path>` URI across the codebase. No Puppet Server or PuppetDB connection required. Individual file URIs are matched exactly; files in directories served with `recurse => true` should be reviewed manually.
- Added `dead_code_detector::unused_templates` task — purely static analysis task that discovers all EPP and ERB templates under module `templates/` directories and checks for their canonical `'<module>/<relative_path>'` reference string across the codebase. No Puppet Server or PuppetDB connection required. Matching is exact due to Puppet's unambiguous module template reference format.
- Added `dead_code_detector::unused_types` task — hybrid analysis that combines static filesystem discovery with live PuppetDB resource data. Detects two categories reported separately: Puppet-language defined types (`define` in `manifests/`) and native Ruby custom types (`Puppet::Type.newtype` in `lib/puppet/type/`). A type is considered unused when it has no instances in any active node's catalog within the staleness window.
- Added `dead_code_detector::unused_functions` task — static analysis of the environment directory on the Primary Server. Discovers all module-defined functions (Puppet-language, modern Ruby API, and legacy Ruby API) and cross-references them against call sites in manifests, functions, templates, and library files. Built-in Puppet language functions are never included; discovery is scoped exclusively to module directories.
- Added `dead_code_detector::used_classes` task — the inverse of the unused classes report. Queries PuppetDB and ranks all applied classes by the number of active nodes they appear on, highest first. Supports a `top_n` parameter to limit results.
- Extracted shared Puppet/PuppetDB client and analyser logic into `files/deadwood.rb` so all tasks share a single library with no duplication.

**Renamed tasks**

- `dead_code_detector::generate` renamed to `dead_code_detector::unused_classes` for clarity.
- `dead_code_detector::class_usage_report` renamed to `dead_code_detector::used_classes` for consistency.



**Documentation**

- Added Puppet Bolt usage instructions as an alternative transport to Puppet Enterprise Orchestrator.
- Clarified that the module supports both Puppet Enterprise and Puppet Core / OpenVox.
- Updated Requirements section to cover Bolt-specific prerequisites (SSH access, Bolt installation).
- Added `bolt module install` and `bolt task run` examples, including optional parameter usage.

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
