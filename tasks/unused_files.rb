#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'json'
require_relative '../files/deadwood'

# =============================================================================
# Task entry point – dead_code_detector::unused_files
#
# Purely static analysis; no Puppet Server or PuppetDB API calls are made.
# Discovers all files under module files/ directories and checks whether their
# canonical puppet:///modules/<mod>/<path> URI appears anywhere in the codebase.
#
# Files with no matching URI in any manifest, function, ERB template, or Ruby
# library are reported as unused.
#
# NOTE: Directory URIs (used with `recurse => true`) are not evaluated — only
# individual file URIs are matched. A file inside a directory that is served
# recursively may appear as unused even if it is deployed via its parent
# directory URI. Review results in modules that use recursive file serving.
# =============================================================================
def puppet_config(key)
  val = `puppet config print #{key} 2>/dev/null`.strip
  val.empty? ? nil : val
end

params      = JSON.parse(STDIN.read)
environment = params['environment'] || 'production'

env_dir = params['env_dir'] ||
          begin
            env_path = puppet_config('environmentpath') || '/etc/puppetlabs/code/environments'
            File.join(env_path.split(':').first, environment)
          end

begin
  result = Deadwood::FileScanner.new.run(env_dir: env_dir)

  meta = {
    environment:  environment,
    env_dir:      env_dir,
    generated_at: Time.now.utc.iso8601
  }

  puts JSON.generate({ meta: meta }.merge(result))
  exit 0
rescue RuntimeError => e
  puts JSON.generate(_error: { msg: e.message, kind: 'deadwood/runtime-error', details: {} })
  exit 1
end
