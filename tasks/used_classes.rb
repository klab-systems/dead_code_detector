#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'json'
require_relative '../files/deadwood'

# =============================================================================
# Task entry point – dead_code_detector::used_classes
# Returns all classes applied in the given environment ranked by the number of
# active nodes they appear on, highest first.  Pass top_n to limit results.
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
top_n             = (params['top_n']             || 0).to_i
cert              = params['cert']    || "#{ssl_dir}/certs/#{certname}.pem"
key               = params['key']     || "#{ssl_dir}/private_keys/#{certname}.pem"
ca_cert           = params['ca_cert'] || "#{ssl_dir}/certs/ca.pem"

begin
  ssl_args = { cert: cert, key: key, ca_cert: ca_cert }
  since    = Time.now - (stale_days * 86_400)

  pdb = Deadwood::PuppetdbClient.new(host: puppetdb_host, port: puppetdb_port, **ssl_args)

  class_node_counts = pdb.fetch_class_node_counts(environment: environment, since: since)
  result            = Deadwood::UsageAnalyzer.new.run(class_node_counts: class_node_counts, top_n: top_n)

  meta = {
    environment:  environment,
    stale_days:   stale_days,
    top_n:        top_n.zero? ? 'all' : top_n,
    puppetdb_host: puppetdb_host,
    puppetdb_port: puppetdb_port,
    generated_at: Time.now.utc.iso8601
  }

  puts JSON.generate({ meta: meta }.merge(result))
  exit 0
rescue RuntimeError => e
  puts JSON.generate(_error: { msg: e.message, kind: 'deadwood/runtime-error', details: {} })
  exit 1
end
