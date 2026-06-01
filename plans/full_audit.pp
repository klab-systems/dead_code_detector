# @summary
#   Runs all dead_code_detector tasks against a Puppet Primary Server
#   and returns a single organised audit report.
#
# @param targets
#   The Puppet Primary Server to target. Must be a single node.
#
# @param environment
#   Puppet environment to analyse. Defaults to 'production'.
#
# @param stale_days
#   Exclude nodes whose last report is older than this many days (applies to
#   unused_classes and unused_types). Defaults to 30.
#
# @param env_dir
#   Absolute path to the environment directory on the Primary Server.
#   Derived automatically from `puppet config print environmentpath` when omitted.
#   Used by unused_functions, unused_types, unused_templates, unused_files,
#   and analyze_hieradata.
#
# @param hiera_sort
#   Sort order for analyze_hieradata results. 'asc' (default) lists least-referenced
#   hiera keys first. 'desc' lists most-referenced keys first.
#
# @param puppetserver_host
#   Hostname or IP of the Puppet Server (unused_classes only). Defaults to the
#   target node's certname.
#
# @param puppetdb_host
#   Hostname or IP of PuppetDB (unused_classes, unused_types). Defaults to the
#   target node's certname.
#
# @param puppetserver_port
#   Puppet Server HTTPS port. Defaults to 8140.
#
# @param puppetdb_port
#   PuppetDB HTTPS port. Defaults to 8081.
#
# @param cert
#   Path to a PEM-encoded client certificate on the Primary Server.
#
# @param key
#   Path to a PEM-encoded client private key on the Primary Server.
#
# @param ca_cert
#   Path to the PEM-encoded CA certificate on the Primary Server.
#
plan dead_code_detector::full_audit(
  TargetSpec        $targets,
  String            $environment       = 'production',
  Integer           $stale_days        = 30,
  Optional[String]  $env_dir           = undef,
  Enum[asc, desc]   $hiera_sort        = 'asc',
  Optional[String]  $puppetserver_host = undef,
  Optional[String]  $puppetdb_host     = undef,
  Optional[Integer] $puppetserver_port = undef,
  Optional[Integer] $puppetdb_port     = undef,
  Optional[String]  $cert              = undef,
  Optional[String]  $key               = undef,
  Optional[String]  $ca_cert           = undef,
) {
  # ------------------------------------------------------------------
  # Build parameter sets for each task group
  # ------------------------------------------------------------------

  # Base PuppetDB params shared by unused_classes and unused_types
  $pdb_base = {
    'environment' => $environment,
    'stale_days'  => $stale_days,
  }
  $pdb_params = $pdb_base
    + if $puppetdb_host     { { 'puppetdb_host'     => $puppetdb_host     } } else { {} }
    + if $puppetdb_port     { { 'puppetdb_port'     => $puppetdb_port     } } else { {} }
    + if $cert              { { 'cert'              => $cert              } } else { {} }
    + if $key               { { 'key'               => $key               } } else { {} }
    + if $ca_cert           { { 'ca_cert'           => $ca_cert           } } else { {} }

  # unused_classes also needs Puppet Server connection params
  $classes_params = $pdb_params
    + if $puppetserver_host { { 'puppetserver_host' => $puppetserver_host } } else { {} }
    + if $puppetserver_port { { 'puppetserver_port' => $puppetserver_port } } else { {} }

  # unused_types additionally needs env_dir for its filesystem scanner
  $types_params = $pdb_params
    + if $env_dir           { { 'env_dir'           => $env_dir           } } else { {} }

  # Filesystem-only params: unused_functions, unused_templates, unused_files
  $fs_params = { 'environment' => $environment }
    + if $env_dir           { { 'env_dir'           => $env_dir           } } else { {} }

  # analyze_hieradata params
  $hiera_params = { 'environment' => $environment, 'sort' => $hiera_sort }
    + if $env_dir           { { 'env_dir'           => $env_dir           } } else { {} }

  # ------------------------------------------------------------------
  # Run all tasks
  # ------------------------------------------------------------------
  out::message('[ 1/6 ] Running unused_classes ...')
  $r_classes   = run_task('dead_code_detector::unused_classes',   $targets, $classes_params)

  out::message('[ 2/6 ] Running unused_types ...')
  $r_types     = run_task('dead_code_detector::unused_types',     $targets, $types_params)

  out::message('[ 3/6 ] Running unused_functions ...')
  $r_functions = run_task('dead_code_detector::unused_functions', $targets, $fs_params)

  out::message('[ 4/6 ] Running unused_templates ...')
  $r_templates = run_task('dead_code_detector::unused_templates', $targets, $fs_params)

  out::message('[ 5/6 ] Running unused_files ...')
  $r_files     = run_task('dead_code_detector::unused_files',     $targets, $fs_params)

  out::message('[ 6/6 ] Running analyze_hieradata ...')
  $r_hiera     = run_task('dead_code_detector::analyze_hieradata', $targets, $hiera_params)

  # ------------------------------------------------------------------
  # Assemble combined report
  # ------------------------------------------------------------------
  $cv = $r_classes.first.value
  $tv = $r_types.first.value
  $fv = $r_functions.first.value
  $mv = $r_templates.first.value
  $lv = $r_files.first.value
  $hv = $r_hiera.first.value

  $report = {
    'meta' => {
      'environment'  => $environment,
      'stale_days'   => $stale_days,
      'generated_at' => strftime(Timestamp(), '%Y-%m-%dT%H:%M:%SZ'),
      'target'       => $targets,
    },
    'plan_summary' => {
      'unused_classes'         => $cv['unused_classes'].length,
      'unused_defined_types'   => $tv['unused_defined_types'].length,
      'unused_custom_types'    => $tv['unused_custom_types'].length,
      'unused_functions'       => $fv['unused_functions'].length,
      'unused_templates'       => $mv['unused_templates'].length,
      'unused_static_files'    => $lv['unused_files'].length,
      'hiera_keys_total'       => $hv['summary']['total_keys'],
      'hiera_keys_single_file' => $hv['summary']['keys_in_single_file'],
    },
    'unused_classes' => {
      'classes' => $cv['unused_classes'],
      'modules' => $cv['unused_modules'],
    },
    'unused_types' => {
      'defined_types' => $tv['unused_defined_types'],
      'custom_types'  => $tv['unused_custom_types'],
    },
    'unused_functions' => {
      'functions' => $fv['unused_functions'],
      'warnings'  => $fv['warnings'],
    },
    'unused_templates' => {
      'templates' => $mv['unused_templates'],
    },
    'unused_files' => {
      'files' => $lv['unused_files'],
    },
    'hieradata' => {
      'hiera_keys' => $hv['hiera_keys'],
      'warnings'   => $hv['warnings'],
    },
  }

  # ------------------------------------------------------------------
  # Print summary
  # ------------------------------------------------------------------
  out::message("\nAudit complete.")
  out::message("  Unused classes:         ${$report['unused_classes']['classes'].length}")
  out::message("  Unused defined types:   ${$report['unused_types']['defined_types'].length}")
  out::message("  Unused custom types:    ${$report['unused_types']['custom_types'].length}")
  out::message("  Unused functions:       ${$report['unused_functions']['functions'].length}")
  out::message("  Unused templates:       ${$report['unused_templates']['templates'].length}")
  out::message("  Unused static files:    ${$report['unused_files']['files'].length}")
  out::message("  Hiera keys (total):     ${$report['plan_summary']['hiera_keys_total']}")
  out::message("  Hiera keys (1 file):    ${$report['plan_summary']['hiera_keys_single_file']}")

  return $report
}
