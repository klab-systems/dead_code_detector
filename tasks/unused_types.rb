#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'json'
require_relative '../files/deadwood'

# =============================================================================
# Task entry point – dead_code_detector::unused_types
#
# Hybrid analysis task combining static filesystem discovery with live PuppetDB
# cross-referencing. Two categories of module-provided types are detected:
#
#   defined_type — Puppet-language defined types (define keyword in manifests/)
#   custom_type  — Native Ruby types (Puppet::Type.newtype in lib/puppet/type/)
#
# Both appear as resources in PuppetDB when instantiated, enabling accurate
# detection without relying on call-site text scanning alone.
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
ssl_dir     = '/etc/puppetlabs/puppet/ssl'
certname    = resolve_certname
environment = params['environment'] || 'production'

env_dir = params['env_dir'] ||
          begin
            env_path = puppet_config('environmentpath') || '/etc/puppetlabs/code/environments'
            File.join(env_path.split(':').first, environment)
          end

modules_dir   = params['modules_dir'] || File.join(env_dir, 'modules')
puppetdb_host = params['puppetdb_host'] || certname
puppetdb_port = (params['puppetdb_port'] || 8081).to_i
stale_days    = (params['stale_days']    || 30).to_i
cert          = params['cert']    || "#{ssl_dir}/certs/#{certname}.pem"
key           = params['key']     || "#{ssl_dir}/private_keys/#{certname}.pem"
ca_cert       = params['ca_cert'] || "#{ssl_dir}/certs/ca.pem"

begin
  ssl_args = { cert: cert, key: key, ca_cert: ca_cert }
  since    = Time.now - (stale_days * 86_400)

  pdb = Deadwood::PuppetdbClient.new(host: puppetdb_host, port: puppetdb_port, **ssl_args)

  applied_resource_types = pdb.fetch_applied_resource_types(environment: environment, since: since)
  result                 = Deadwood::TypeScanner.new.run(
    modules_dir:            modules_dir,
    applied_resource_types: applied_resource_types
  )

  meta = {
    environment:   environment,
    env_dir:       env_dir,
    modules_dir:   modules_dir,
    stale_days:    stale_days,
    puppetdb_host: puppetdb_host,
    puppetdb_port: puppetdb_port,
    generated_at:  Time.now.utc.iso8601
  }

  puts JSON.generate({ meta: meta }.merge(result))
  exit 0
rescue RuntimeError => e
  puts JSON.generate(_error: { msg: e.message, kind: 'deadwood/runtime-error', details: {} })
  exit 1
end
