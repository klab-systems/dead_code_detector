#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'json'
require_relative '../files/deadwood'

# =============================================================================
# Task entry point – dead_code_detector::analyze_hieradata
#
# Purely static analysis; no Puppet Server or PuppetDB API calls are made.
# Reads the environment-level hiera.yaml to discover all declared data
# directories, then parses every YAML file found under those directories.
#
# For each top-level hiera key found, a frequency count is produced: how many
# files the key appears in and which files contain it. Results are sorted from
# least popular (fewest files, default) to most popular, or the inverse via
# the sort parameter.
#
# Only the control-repo environment data directories are scanned — module-level
# hiera data is excluded.
# =============================================================================
def puppet_config(key)
  val = `puppet config print #{key} 2>/dev/null`.strip
  val.empty? ? nil : val
end

params      = JSON.parse(STDIN.read)
environment = params['environment'] || 'production'
sort_param  = params['sort'] || 'asc'
sort_order  = sort_param == 'desc' ? :desc : :asc

env_dir = params['env_dir'] ||
          begin
            env_path = puppet_config('environmentpath') || '/etc/puppetlabs/code/environments'
            File.join(env_path.split(':').first, environment)
          end

begin
  result = Deadwood::HieraScanner.new.run(env_dir: env_dir, sort_order: sort_order)

  total_keys          = result.delete(:total_keys)
  total_files_scanned = result.delete(:total_files_scanned)
  data_dirs           = result.delete(:data_dirs)
  keys_in_single_file = result[:hiera_keys].count { |e| e[:file_count] == 1 }

  meta = {
    environment:  environment,
    env_dir:      env_dir,
    hiera_yaml:   File.join(env_dir, 'hiera.yaml'),
    data_dirs:    data_dirs,
    sort:         sort_param,
    generated_at: Time.now.utc.iso8601
  }

  task_summary = {
    total_keys:          total_keys,
    total_files_scanned: total_files_scanned,
    keys_in_single_file: keys_in_single_file,
    warning_count:       result[:warnings].size,
  }

  puts JSON.generate({
    meta:       meta,
    summary:    task_summary,
    hiera_keys: result[:hiera_keys],
    warnings:   result[:warnings],
  })
  exit 0
rescue RuntimeError => e
  puts JSON.generate(_error: { msg: e.message, kind: 'deadwood/runtime-error', details: {} })
  exit 1
end
