#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'json'
require_relative '../files/deadwood'

# =============================================================================
# Task entry point – dead_code_detector::unused_templates
#
# Purely static analysis; no Puppet Server or PuppetDB API calls are made.
# Discovers all EPP and ERB templates in module directories, then searches for
# their canonical module references ('mymod/path/to/file.epp') across the
# codebase. Templates with no call sites are reported as unused.
#
# Matching is exact by design: Puppet resolves module templates exclusively via
# the '<module_name>/<path_relative_to_templates/>' notation, so there is no
# partial-name false-positive risk of the kind that affects function scanning.
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
  result = Deadwood::TemplateScanner.new.run(env_dir: env_dir)

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
