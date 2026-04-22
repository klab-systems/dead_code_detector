#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'json'
require_relative '../files/deadwood'

# =============================================================================
# Task entry point – dead_code_detector::unused_functions
#
# Static analysis task. No API calls are made — discovery and call-site
# scanning operate entirely on the local filesystem of the Primary Server.
#
# Because discovery is scoped to module directories only, built-in Puppet
# language functions are never registered and therefore never appear in the
# report.
# =============================================================================
def resolve_certname
  certname = `puppet config print certname 2>/dev/null`.strip
  certname.empty? ? `hostname -f`.strip : certname
end

def puppet_config(key)
  val = `puppet config print #{key} 2>/dev/null`.strip
  val.empty? ? nil : val
end

params      = JSON.parse(STDIN.read)
environment = params['environment'] || 'production'

# Resolve the environment directory. Allow explicit override via parameter,
# otherwise derive from `puppet config print environmentpath`.
env_dir = params['env_dir'] ||
          begin
            env_path = puppet_config('environmentpath') || '/etc/puppetlabs/code/environments'
            File.join(env_path.split(':').first, environment)
          end

begin
  result = Deadwood::FunctionScanner.new.run(env_dir: env_dir)

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
