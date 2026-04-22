#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'json'
require_relative '../files/deadwood'

# =============================================================================
# Task entry point – dead_code_detector::unused_classes
# =============================================================================
def resolve_certname
  certname = `puppet config print certname 2>/dev/null`.strip
  certname.empty? ? `hostname -f`.strip : certname
end

params   = JSON.parse(STDIN.read)
ssl_dir  = '/etc/puppetlabs/puppet/ssl'
certname = resolve_certname

puppetserver_host = params['puppetserver_host'] || certname
puppetdb_host     = params['puppetdb_host']     || certname
puppetserver_port = (params['puppetserver_port'] || 8140).to_i
puppetdb_port     = (params['puppetdb_port']     || 8081).to_i
environment       = params['environment']        || 'production'
stale_days        = (params['stale_days']        || 30).to_i
cert              = params['cert']    || "#{ssl_dir}/certs/#{certname}.pem"
key               = params['key']     || "#{ssl_dir}/private_keys/#{certname}.pem"
ca_cert           = params['ca_cert'] || "#{ssl_dir}/certs/ca.pem"

begin
  ssl_args = { cert: cert, key: key, ca_cert: ca_cert }
  since    = Time.now - (stale_days * 86_400)

  ps  = Deadwood::PuppetServerClient.new(host: puppetserver_host, port: puppetserver_port, **ssl_args)
  pdb = Deadwood::PuppetdbClient.new(host: puppetdb_host,         port: puppetdb_port,     **ssl_args)

  defined_classes     = ps.fetch_classes(environment: environment)
  applied_class_names = pdb.fetch_applied_classes(environment: environment, since: since)
  result              = Deadwood::DeadCodeAnalyzer.new.run(defined_classes: defined_classes,
                                                           applied_class_names: applied_class_names)

  meta = {
    environment:       environment,
    stale_days:        stale_days,
    puppetserver_host: puppetserver_host,
    puppetserver_port: puppetserver_port,
    puppetdb_host:     puppetdb_host,
    puppetdb_port:     puppetdb_port,
    generated_at:      Time.now.utc.iso8601
  }

  puts JSON.generate(Deadwood::Reporter.new.render(result: result, meta: meta))
  exit 0
rescue RuntimeError => e
  puts JSON.generate(_error: { msg: e.message, kind: 'deadwood/runtime-error', details: {} })
  exit 1
end
