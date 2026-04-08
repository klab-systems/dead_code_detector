#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'json'
require 'uri'
require 'set'
require 'time'

# =============================================================================
# PuppetServerClient
# Fetches class definitions from the Puppet Server environment_classes API.
# =============================================================================
module Deadwood
  class PuppetServerClient
    def initialize(host:, port:, cert:, key:, ca_cert:)
      @host    = host
      @port    = port
      @cert    = cert
      @key     = key
      @ca_cert = ca_cert
    end

    def fetch_classes(environment:)
      path     = "/puppet/v3/environment_classes?environment=#{URI.encode_uri_component(environment)}"
      response = request(path)
      parse_class_names(response.body)
    end

    private

    def request(path)
      response = build_http.request(Net::HTTP::Get.new(path))
      return response if response.code == '200'

      raise "Puppet Server returned HTTP #{response.code} for #{path}"
    end

    def build_http
      http             = Net::HTTP.new(@host, @port)
      http.use_ssl     = true
      http.cert        = OpenSSL::X509::Certificate.new(File.read(@cert))
      http.key         = OpenSSL::PKey::RSA.new(File.read(@key))
      http.ca_file     = @ca_cert
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http
    end

    def parse_class_names(body)
      data = JSON.parse(body)
      data['files']
        .reject { |f| f.key?('error') }
        .flat_map { |f| f['classes'].map { |c| c['name'].downcase } }
    rescue JSON::ParserError => e
      raise "Invalid JSON from Puppet Server: #{e.message}"
    end
  end

  # ===========================================================================
  # PuppetdbClient
  # Fetches applied class names from PuppetDB for active nodes.
  # ===========================================================================
  class PuppetdbClient
    LIMIT          = 10_000
    EXCLUDED_NAMES = %w[class settings].freeze

    def initialize(host:, port:, cert:, key:, ca_cert:)
      @host    = host
      @port    = port
      @cert    = cert
      @key     = key
      @ca_cert = ca_cert
    end

    def fetch_applied_classes(environment:, since:)
      result = Set.new
      offset = 0
      loop do
        page = fetch_page(environment: environment, since: since, offset: offset)
        break if page.empty?

        page.each { |r| result.add(r['title'].downcase) unless EXCLUDED_NAMES.include?(r['title'].downcase) }
        break if page.size < LIMIT

        offset += LIMIT
      end
      result
    end

    private

    def fetch_page(environment:, since:, offset:)
      path     = build_path(environment: environment, since: since, offset: offset)
      response = request(path)
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise "Invalid JSON from PuppetDB: #{e.message}"
    end

    def build_path(environment:, since:, offset:)
      query    = JSON.generate(build_ast(environment, since))
      order_by = JSON.generate([{ field: 'certname' }, { field: 'title' }])
      params   = URI.encode_www_form(query: query, limit: LIMIT, offset: offset, order_by: order_by)
      "/pdb/query/v4/resources/Class?#{params}"
    end

    def build_ast(environment, since)
      ['and',
       ['=', 'environment', environment],
       ['in', 'certname',
        ['extract', 'certname',
         ['select_nodes',
          ['and',
           ['null?', 'deactivated', true],
           ['null?', 'expired', true],
           ['>=', 'report_timestamp', since.iso8601]]]]]]
    end

    def request(path)
      response = build_http.request(Net::HTTP::Get.new(path))
      return response if response.code == '200'

      raise "PuppetDB returned HTTP #{response.code} for #{path}"
    end

    def build_http
      http             = Net::HTTP.new(@host, @port)
      http.use_ssl     = true
      http.cert        = OpenSSL::X509::Certificate.new(File.read(@cert))
      http.key         = OpenSSL::PKey::RSA.new(File.read(@key))
      http.ca_file     = @ca_cert
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http
    end
  end

  # ===========================================================================
  # Analyzer
  # Computes the set difference between defined and applied Puppet classes.
  # ===========================================================================
  class Analyzer
    PuppetModule = Struct.new(:name, :classes, keyword_init: true)

    def run(defined_classes:, applied_class_names:)
      unused = defined_classes.reject { |c| applied_class_names.include?(c) }.sort
      { unused_classes: unused, unused_modules: wholly_unused_modules(defined_classes, unused) }
    end

    private

    def wholly_unused_modules(defined_classes, unused_classes)
      grouped    = defined_classes.group_by { |c| c.split('::').first }
      unused_set = Set.new(unused_classes)
      grouped.filter_map { |mod_name, classes|
        next unless classes.all? { |c| unused_set.include?(c) }

        PuppetModule.new(name: mod_name, classes: classes)
      }.sort_by(&:name)
    end
  end

  # ===========================================================================
  # Reporter
  # Renders analysis results as a JSON hash.
  # ===========================================================================
  class Reporter
    def render(result:, meta:)
      {
        meta:           meta,
        unused_classes: result[:unused_classes].sort,
        unused_modules: result[:unused_modules].map { |m|
          { name: m.name, unused_class_count: m.classes.size, classes: m.classes }
        }
      }
    end
  end
end

# =============================================================================
# Task entry point
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
  pdb = Deadwood::PuppetdbClient.new(host: puppetdb_host,     port: puppetdb_port,     **ssl_args)

  defined_classes     = ps.fetch_classes(environment: environment)
  applied_class_names = pdb.fetch_applied_classes(environment: environment, since: since)
  result              = Deadwood::Analyzer.new.run(defined_classes: defined_classes,
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
