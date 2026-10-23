# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'json'
require 'uri'
require 'set'
require 'time'
require 'yaml'

# =============================================================================
# Deadwood shared library
# Shared classes used by dead_code_detector tasks.
# =============================================================================
module Deadwood
  # ===========================================================================
  # PuppetServerClient
  # Fetches class definitions from the Puppet Server environment_classes API.
  # ===========================================================================
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
  # Fetches applied class data from PuppetDB for active nodes.
  # ===========================================================================
  class PuppetdbClient
    LIMIT          = 10_000
    EXCLUDED_NAMES = ['class', 'settings'].freeze

    def initialize(host:, port:, cert:, key:, ca_cert:)
      @host    = host
      @port    = port
      @cert    = cert
      @key     = key
      @ca_cert = ca_cert
    end

    # Returns a Set of class name strings that appear in at least one active
    # node's catalog. Used by the dead code report.
    def fetch_applied_classes(environment:, since:)
      result = Set.new
      each_resource_page(environment: environment, since: since) do |record|
        result.add(record['title'].downcase)
      end
      result
    end

    # Returns a Hash of { class_name => node_count } for all active nodes.
    # Used by the class usage report.
    def fetch_class_node_counts(environment:, since:)
      # Track the set of certnames that have applied each class so that a node
      # restarting and generating multiple reports is not double-counted.
      class_nodes = Hash.new { |h, k| h[k] = Set.new }
      each_resource_page(environment: environment, since: since) do |record|
        title = record['title'].downcase
        class_nodes[title].add(record['certname'])
      end
      class_nodes.transform_values(&:size)
    end

    # Returns a Set of lowercase resource type names that appear in active node
    # catalogs for the given environment. Uses an extract+group_by aggregate so
    # only distinct type names are transferred — no per-resource paging needed.
    def fetch_applied_resource_types(environment:, since:)
      ast    = ['extract', [['function', 'count'], 'type'],
                build_ast(environment, since),
                ['group_by', 'type']]
      path   = "/pdb/query/v4/resources?query=#{URI.encode_uri_component(JSON.generate(ast))}"
      body   = request(path).body
      JSON.parse(body).to_set { |r| r['type'].downcase }
    rescue JSON::ParserError => e
      raise "Invalid JSON from PuppetDB (resource types): #{e.message}"
    end

    private

    # Yields each resource record across all pages, skipping excluded names.
    def each_resource_page(environment:, since:)
      offset = 0
      loop do
        page = fetch_page(environment: environment, since: since, offset: offset)
        break if page.empty?

        page.each do |r|
          yield r unless EXCLUDED_NAMES.include?(r['title'].downcase)
        end
        break if page.size < LIMIT

        offset += LIMIT
      end
    end

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
  # DeadCodeAnalyzer
  # Computes the set difference between defined and applied Puppet classes.
  # ===========================================================================
  class DeadCodeAnalyzer
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
  # UsageAnalyzer
  # Ranks classes by how many active nodes have them applied.
  # ===========================================================================
  class UsageAnalyzer
    # class_node_counts - Hash of { class_name => node_count }
    # top_n             - return only the N most-used classes (0 = all)
    def run(class_node_counts:, top_n: 0)
      ranked = class_node_counts
               .sort_by { |_, count| -count }
               .map { |name, count| { class_name: name, node_count: count } }
      ranked = ranked.first(top_n) if top_n.positive?
      { ranked_classes: ranked }
    end
  end

  # ===========================================================================
  # Reporter
  # Renders dead code analysis results as a JSON-ready hash.
  # ===========================================================================
  class Reporter
    def render(result:, meta:)
      {
        meta: meta,
        unused_classes: result[:unused_classes].sort,
        unused_modules: result[:unused_modules].map do |m|
          { name: m.name, unused_class_count: m.classes.size, classes: m.classes }
        end,
      }
    end
  end

  # ===========================================================================
  # ScannerSupport
  #
  # Shared environment validation and source reading for static scanners.
  # ===========================================================================
  module ScannerSupport
    private

    def modules_directory(env_dir)
      raise "Environment directory not found: #{env_dir}" unless File.directory?(env_dir)

      modules_dir = File.join(env_dir, 'modules')
      raise "modules/ directory not found under #{env_dir}" unless File.directory?(modules_dir)

      modules_dir
    end

    def each_source_content(env_dir)
      collect_source_files(env_dir).each do |src|
        begin
          content = File.read(src, encoding: 'UTF-8', invalid: :replace)
        rescue Errno::EACCES
          next
        end
        yield src, content
      end
    end

    def each_source_line(file)
      File.foreach(file, encoding: 'UTF-8').with_index(1) do |line, line_number|
        raise "Invalid UTF-8 in source file #{file}:#{line_number}" unless line.valid_encoding?

        yield line
      end
    end

    def find_references(env_dir, references)
      found = Set.new
      return found if references.empty?

      each_source_content(env_dir) do |_, content|
        references.each { |ref| found.add(ref) if content.include?(ref) }
      end
      found
    end
  end

  # ===========================================================================
  # FunctionScanner
  #
  # Identifies unused module-defined functions via static analysis of the
  # Puppet environment directory on the Primary Server.
  #
  # Built-in Puppet language functions are never registered because discovery
  # is scoped exclusively to module subdirectories — they never appear in any
  # module's functions/ or lib/ tree.
  #
  # Three function styles are detected:
  #
  #   :pp_modern   — Puppet-language functions in modules/<mod>/functions/
  #                  e.g.  function mymod::myfunc(...) { ... }
  #
  #   :ruby_modern — Puppet 4+ Ruby API in modules/<mod>/lib/puppet/functions/
  #                  e.g.  Puppet::Functions.create_function(:'mod::myfunc')
  #
  #   :ruby_legacy — Legacy Ruby API in modules/<mod>/lib/puppet/parser/functions/
  #                  e.g.  Puppet::Parser::Functions.newfunction(:myfunc, ...)
  #                  NOTE: legacy names are unnamespaced; false-positive risk is
  #                  higher for short generic names.
  # ===========================================================================
  class FunctionScanner
    include ScannerSupport

    FunctionDef = Struct.new(:call_name, :qualified_name, :module_name, :source_file, :type, keyword_init: true)

    # Returns a hash:
    #   {
    #     unused_functions: [ { call_name:, qualified_name:, module_name:, source_file:, type: }, ... ],
    #     used_functions:   [ ... ],
    #     warnings:         [ "..." ]
    #   }
    def run(env_dir:)
      functions   = FunctionDiscovery.new.run(modules_directory(env_dir))
      call_sites  = find_call_sites(env_dir, functions.map(&:call_name).uniq)
      used, unused = functions.partition { |f| call_sites.key?(f.call_name) }

      {
        unused_functions: serialize(unused),
        used_functions: serialize(used),
        warnings: build_warnings(functions),
      }
    end

    private

    # -------------------------------------------------------------------------
    # Call-site scanning
    # -------------------------------------------------------------------------

    # Returns a Hash of { call_name => [matched_file, ...] } for functions that
    # have at least one call site. Functions absent from the hash have no hits.
    def find_call_sites(env_dir, call_names)
      return {} if call_names.empty?

      hits         = Hash.new { |h, k| h[k] = [] }
      each_source_content(env_dir) do |src, content|
        call_names.each do |name|
          # Match the function name not immediately preceded or followed by a
          # word character (avoids partial-name false positives).
          hits[name] << src if content.match?(%r{(?<!\w)#{Regexp.escape(name)}(?!\w)})
        end
      end

      hits
    end

    # All Puppet source files in the environment that could contain call sites.
    def collect_source_files(env_dir)
      patterns = [
        File.join(env_dir, 'manifests',   '**', '*.pp'),
        File.join(env_dir, 'modules',     '**', 'manifests', '**', '*.pp'),
        File.join(env_dir, 'modules',     '**', 'functions',  '**', '*.pp'),
        File.join(env_dir, 'modules',     '**', 'templates',  '**', '*.epp'),
        File.join(env_dir, 'modules',     '**', 'lib',        '**', '*.rb'),
        File.join(env_dir, 'site',        '**', '*.pp'),
      ]
      patterns.flat_map { |p| Dir.glob(p) }.uniq
    end

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    def build_warnings(functions)
      warnings = []
      legacy = functions.select { |f| f.type == :ruby_legacy }
      unless legacy.empty?
        warnings << ("#{legacy.size} legacy Ruby function(s) detected (type: ruby_legacy). " \
                     'Legacy function names are unnamespaced, which increases the risk of ' \
                     'false negatives if the name is generic (e.g. "validate_string"). ' \
                     'Review these results manually: ' + legacy.map(&:call_name).join(', '))
      end
      warnings
    end

    # Discovers declarations while retaining legacy functions' unqualified call names.
    class FunctionDiscovery
      include ScannerSupport

      STYLES = {
        pp_modern: ['functions', '**', '*.pp'],
        ruby_modern: ['lib', 'puppet', 'functions', '**', '*.rb'],
        ruby_legacy: ['lib', 'puppet', 'parser', 'functions', '*.rb'],
      }.freeze
      NAME_PATTERNS = {
        pp_modern: %r{^\s*function\s+([\w:]+)\s*[\(\|]},
        ruby_modern: %r{create_function\s*\(\s*[:"']+([\w:]+)['":]?\s*\)},
        ruby_legacy: %r{newfunction\s*\(\s*:(\w+)},
      }.freeze

      def run(modules_dir)
        functions = Dir.glob(File.join(modules_dir, '*')).flat_map do |mod_path|
          next [] unless File.directory?(mod_path)

          STYLES.flat_map { |type, pattern| discover_functions(mod_path, type, pattern) }
        end
        functions.uniq(&:qualified_name).sort_by(&:qualified_name)
      end

      private

      def discover_functions(mod_path, type, pattern)
        Dir.glob(File.join(mod_path, *pattern)).filter_map do |file|
          name = extract_name(file, type)
          next unless name

          function_definition(name, File.basename(mod_path), file, type)
        end
      end

      def function_definition(name, mod_name, file, type)
        FunctionScanner::FunctionDef.new(
          call_name: name,
          qualified_name: (type == :ruby_legacy) ? "#{mod_name}::#{name}" : name,
          module_name: mod_name,
          source_file: file,
          type: type,
        )
      end

      def extract_name(file, type)
        each_source_line(file) do |line|
          match = line.match(NAME_PATTERNS.fetch(type))
          return match[1].downcase if match
        end
        # Legacy functions without a parsable declaration use their filename.
        File.basename(file, '.rb').downcase if type == :ruby_legacy
      end
    end

    def serialize(functions)
      functions.map do |f|
        {
          call_name: f.call_name,
          qualified_name: f.qualified_name,
          module_name: f.module_name,
          source_file: f.source_file,
          type: f.type.to_s,
        }
      end
    end
  end

  # ===========================================================================
  # TypeScanner
  #
  # Discovers all module-provided Puppet types via static filesystem analysis.
  # Two categories are handled:
  #
  #   :defined_type  — Puppet-language defined types declared with the `define`
  #                    keyword inside modules/<mod>/manifests/**/*.pp
  #                    Names are fully qualified (mymod::mytype).
  #                    In PuppetDB these appear as resource type Mymod::Mytype.
  #
  #   :custom_type   — Native Ruby types declared with Puppet::Type.newtype in
  #                    modules/<mod>/lib/puppet/type/*.rb
  #                    Names are unnamespaced (mytype).
  #                    In PuppetDB these appear as resource type Mytype.
  #
  # Detection is hybrid: types are discovered statically, then cross-referenced
  # against PuppetDB resource data so only truly uninstantiated types are
  # reported as unused.
  # ===========================================================================
  class TypeScanner
    include ScannerSupport

    TypeDef = Struct.new(:name, :pdb_type_name, :module_name, :source_file, :kind, keyword_init: true)

    # Returns a hash:
    #   {
    #     unused_defined_types: [ { name:, module_name:, source_file:, instance_count: 0 }, ... ],
    #     unused_custom_types:  [ { name:, module_name:, source_file:, instance_count: 0 }, ... ],
    #     used_defined_types:   [ { ..., instance_count: N }, ... ],
    #     used_custom_types:    [ { ..., instance_count: N }, ... ]
    #   }
    def run(modules_dir:, applied_resource_types:)
      raise "modules/ directory not found: #{modules_dir}" unless File.directory?(modules_dir)

      all_types   = discover_all_types(modules_dir)
      type_counts = build_type_counts(all_types, applied_resource_types)

      unused_defined = type_counts.select { |t, count| t.kind == :defined_type && count.zero? }
      unused_custom  = type_counts.select { |t, count| t.kind == :custom_type  && count.zero? }

      {
        unused_defined_types: serialize_types(unused_defined, include_count: false),
        unused_custom_types: serialize_types(unused_custom, include_count: false),
      }
    end

    private

    # -------------------------------------------------------------------------
    # Discovery
    # -------------------------------------------------------------------------

    def discover_all_types(modules_dir)
      types = []
      Dir.glob(File.join(modules_dir, '*')).each do |mod_path|
        next unless File.directory?(mod_path)

        mod_name = File.basename(mod_path)
        types.concat(discover_defined_types(mod_path, mod_name))
        types.concat(discover_custom_types(mod_path,  mod_name))
      end
      types.uniq(&:name).sort_by(&:name)
    end

    # modules/<mod>/manifests/**/*.pp — scans for `define mod::name` declarations
    def discover_defined_types(mod_path, mod_name)
      Dir.glob(File.join(mod_path, 'manifests', '**', '*.pp')).filter_map do |file|
        name = extract_defined_type_name(file)
        next unless name

        # PuppetDB stores defined type instances with each segment capitalised,
        # e.g. "mymod::mytype" → resource type "Mymod::Mytype"
        pdb_name = name.split('::').map(&:capitalize).join('::')
        type_definition(name, pdb_name, mod_name, file, :defined_type)
      end
    end

    # modules/<mod>/lib/puppet/type/*.rb — scans for Puppet::Type.newtype declarations
    def discover_custom_types(mod_path, mod_name)
      Dir.glob(File.join(mod_path, 'lib', 'puppet', 'type', '*.rb')).filter_map do |file|
        name = extract_custom_type_name(file)
        next unless name

        # Custom types appear in PuppetDB with a simple capitalised name,
        # e.g. "mytype" → resource type "Mytype"
        pdb_name = name.capitalize
        type_definition(name, pdb_name, mod_name, file, :custom_type)
      end
    end

    def type_definition(name, pdb_name, mod_name, file, kind)
      TypeDef.new(
        name: name,
        pdb_type_name: pdb_name,
        module_name: mod_name,
        source_file: file,
        kind: kind,
      )
    end

    # -------------------------------------------------------------------------
    # Name extraction
    # -------------------------------------------------------------------------

    def extract_defined_type_name(file)
      each_source_line(file) do |line|
        m = line.match(%r{^\s*define\s+([\w:]+)\s*[\(\|\{]?})
        return m[1].downcase if m
      end
      nil
    end

    def extract_custom_type_name(file)
      each_source_line(file) do |line|
        # Puppet::Type.newtype(:name) or Puppet::Type.newtype('name')
        m = line.match(%r{newtype\s*\(\s*[:'"](\w+)})
        return m[1].downcase if m
      end
      # Fall back to filename if declaration line can't be parsed
      File.basename(file, '.rb').downcase
    end

    # -------------------------------------------------------------------------
    # PuppetDB cross-reference
    # -------------------------------------------------------------------------

    # Returns Hash of { TypeDef => instance_count }
    # applied_resource_types is a Set of lowercase type name strings from PuppetDB.
    def build_type_counts(all_types, applied_resource_types)
      all_types.each_with_object({}) do |type_def, counts|
        counts[type_def] = applied_resource_types.include?(type_def.pdb_type_name.downcase) ? 1 : 0
      end
    end

    # -------------------------------------------------------------------------
    # Serialization
    # -------------------------------------------------------------------------

    def serialize_types(type_count_pairs, include_count:)
      entries = type_count_pairs.map do |type_def, count|
        entry = serialize_type(type_def)
        entry[:instance_count] = count if include_count
        entry
      end
      entries.sort_by { |e| e[:name] }
    end

    def serialize_type(type_def)
      {
        name: type_def.name,
        kind: type_def.kind.to_s,
        module_name: type_def.module_name,
        source_file: type_def.source_file,
      }
    end
  end

  # ===========================================================================
  # TemplateScanner
  #
  # Identifies unused module templates via static analysis.
  # Two template formats are detected:
  #
  #   :epp  — Puppet-language templates in modules/<mod>/templates/**/*.epp
  #           Called via epp('mymod/path/to/file.epp') or inline EPP.
  #
  #   :erb  — Legacy Ruby ERB templates in modules/<mod>/templates/**/*.erb
  #           Called via template('mymod/path/to/file.erb').
  #
  # Detection is reliable: Puppet always resolves module templates using the
  # canonical reference format '<module_name>/<path_relative_to_templates/>',
  # which encodes both the module and the file path unambiguously. This means
  # matching is exact — no partial-name false-positive risk.
  # ===========================================================================
  class TemplateScanner
    include ScannerSupport

    TemplateDef = Struct.new(:reference, :module_name, :format, :source_file, keyword_init: true)

    # Returns a hash:
    #   {
    #     unused_templates: [ { reference:, module_name:, format:, source_file: }, ... ],
    #     used_templates:   [ ... ]
    #   }
    def run(env_dir:)
      templates   = discover_templates(modules_directory(env_dir))
      call_sites  = find_references(env_dir, templates.map(&:reference))
      used, unused = templates.partition { |t| call_sites.include?(t.reference) }

      {
        unused_templates: serialize(unused),
        used_templates: serialize(used),
      }
    end

    private

    # -------------------------------------------------------------------------
    # Discovery
    # -------------------------------------------------------------------------

    def discover_templates(modules_dir)
      templates = []
      Dir.glob(File.join(modules_dir, '*')).each do |mod_path|
        next unless File.directory?(mod_path)

        templates.concat(discover_module_templates(mod_path))
      end
      templates.sort_by(&:reference)
    end

    def discover_module_templates(mod_path)
      templates_dir = File.join(mod_path, 'templates')
      return [] unless File.directory?(templates_dir)

      Dir.glob(File.join(templates_dir, '**', '*.{epp,erb}')).map do |file|
        template_definition(file, templates_dir, File.basename(mod_path))
      end
    end

    def template_definition(file, templates_dir, mod_name)
      TemplateDef.new(
        reference: "#{mod_name}/#{file.sub("#{templates_dir}/", '')}",
        module_name: mod_name,
        format: (File.extname(file) == '.epp') ? :epp : :erb,
        source_file: file,
      )
    end

    # All manifest, function, and library files that could contain template calls.
    # EPP template files themselves are excluded — an EPP cannot call itself.
    def collect_source_files(env_dir)
      patterns = [
        File.join(env_dir, 'manifests',   '**', '*.pp'),
        File.join(env_dir, 'modules',     '**', 'manifests', '**', '*.pp'),
        File.join(env_dir, 'modules',     '**', 'functions',   '**', '*.pp'),
        File.join(env_dir, 'modules',     '**', 'lib',         '**', '*.rb'),
        File.join(env_dir, 'site',        '**', '*.pp'),
      ]
      patterns.flat_map { |p| Dir.glob(p) }.uniq
    end

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    def serialize(templates)
      templates.map do |t|
        {
          reference: t.reference,
          module_name: t.module_name,
          format: t.format.to_s,
          source_file: t.source_file,
        }
      end
    end
  end

  # ===========================================================================
  # FileScanner
  #
  # Identifies unused static files served from module files/ directories.
  #
  # Puppet serves module static files exclusively via the URI scheme:
  #   puppet:///modules/<module_name>/<path_relative_to_files_dir>
  #
  # Examples:
  #   source => 'puppet:///modules/mymod/config/app.conf'
  #   source => 'puppet:///modules/mymod/scripts/deploy.sh'
  #
  # Because the full module-relative file path is always embedded in the URI,
  # matching is exact — no regex or word-boundary tricks are needed. This makes
  # FileScanner the most reliable of the static scanners.
  #
  # Note: directories inside files/ are not reported — Puppet can recurse into
  # them with `recurse => true` using the directory URI, so we surface only
  # individual files as candidates.
  # ===========================================================================
  class FileScanner
    include ScannerSupport

    FileDef = Struct.new(:uri, :module_name, :source_file, keyword_init: true)

    # Returns a hash:
    #   {
    #     unused_files: [ { uri:, module_name:, source_file: }, ... ],
    #     used_files:   [ ... ]
    #   }
    def run(env_dir:)
      file_defs   = discover_module_files(modules_directory(env_dir))
      used_uris   = find_references(env_dir, file_defs.map(&:uri))
      used, unused = file_defs.partition { |f| used_uris.include?(f.uri) }

      {
        unused_files: serialize(unused),
        used_files: serialize(used),
      }
    end

    private

    # -------------------------------------------------------------------------
    # Discovery
    # -------------------------------------------------------------------------

    def discover_module_files(modules_dir)
      file_defs = []
      Dir.glob(File.join(modules_dir, '*')).each do |mod_path|
        next unless File.directory?(mod_path)

        file_defs.concat(discover_files(mod_path))
      end
      file_defs.sort_by(&:uri)
    end

    def discover_files(mod_path)
      files_dir = File.join(mod_path, 'files')
      return [] unless File.directory?(files_dir)

      Dir.glob(File.join(files_dir, '**', '*')).filter_map do |path|
        next if File.directory?(path)

        file_definition(path, files_dir, File.basename(mod_path))
      end
    end

    def file_definition(path, files_dir, mod_name)
      FileDef.new(
        uri: "puppet:///modules/#{mod_name}/#{path.sub("#{files_dir}/", '')}",
        module_name: mod_name,
        source_file: path,
      )
    end

    # All manifest, function, and library files that could contain file resource
    # source attributes. ERB templates are included as they can contain manifests
    # rendered dynamically. EPP templates are excluded — they cannot assign resources.
    def collect_source_files(env_dir)
      patterns = [
        File.join(env_dir, 'manifests',   '**', '*.pp'),
        File.join(env_dir, 'modules',     '**', 'manifests', '**', '*.pp'),
        File.join(env_dir, 'modules',     '**', 'functions',   '**', '*.pp'),
        File.join(env_dir, 'modules',     '**', 'templates',   '**', '*.erb'),
        File.join(env_dir, 'modules',     '**', 'lib',         '**', '*.rb'),
        File.join(env_dir, 'site',        '**', '*.pp'),
      ]
      patterns.flat_map { |p| Dir.glob(p) }.uniq
    end

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    def serialize(file_defs)
      file_defs.map do |f|
        {
          uri: f.uri,
          module_name: f.module_name,
          source_file: f.source_file,
        }
      end
    end
  end

  # ===========================================================================
  # HieraScanner
  #
  # Audits hieradata from the control-repo environment layer. Reads the
  # environment-level hiera.yaml to locate all declared data directories, then
  # parses every YAML file found under those directories.
  #
  # For each top-level key discovered, the scanner records how many files it
  # appears in and which files contain it. This frequency count is a practical
  # staleness signal: a key that appears in only one file out of many is a
  # better candidate for review than one referenced across dozens of hierarchy
  # levels.
  #
  # Only data directories declared in the environment-level hiera.yaml are
  # scanned — module-level hiera data is excluded entirely.
  # ===========================================================================
  class HieraScanner
    # Returns a hash:
    #   {
    #     hiera_keys:          [ { key:, file_count:, files: [...] }, ... ],
    #     data_dirs:           [ '/abs/path/to/datadir', ... ],
    #     total_keys:          Integer,
    #     total_files_scanned: Integer,
    #     warnings:            [ '...' ]
    #   }
    def run(env_dir:, sort_order: :asc)
      raise "Environment directory not found: #{env_dir}" unless File.directory?(env_dir)

      hiera_yaml_path = File.join(env_dir, 'hiera.yaml')
      raise "hiera.yaml not found in #{env_dir}" unless File.exist?(hiera_yaml_path)

      data_dirs = resolve_data_dirs(env_dir, hiera_yaml_path)
      key_files, files_scanned, warnings = scan_data_dirs(data_dirs)
      ranked = rank_keys(key_files, sort_order)

      build_result(ranked, data_dirs, files_scanned, warnings)
    end

    private

    def build_result(ranked, data_dirs, files_scanned, warnings)
      {
        hiera_keys: ranked,
        data_dirs: data_dirs,
        total_keys: ranked.size,
        total_files_scanned: files_scanned,
        warnings: warnings,
      }
    end

    def scan_data_dirs(data_dirs)
      warnings = []
      key_files = Hash.new { |h, k| h[k] = [] }
      files_scanned = data_dirs.sum do |data_dir|
        scan_data_dir(data_dir, key_files, warnings)
      end
      [key_files, files_scanned, warnings]
    end

    def scan_data_dir(data_dir, key_files, warnings)
      unless File.directory?(data_dir)
        warnings << "Data directory not found, skipping: #{data_dir}"
        return 0
      end

      yaml_files = Dir.glob(File.join(data_dir, '**', '*.yaml'))
      yaml_files.each do |yaml_file|
        relative = yaml_file.sub("#{data_dir}/", '')
        extract_keys(yaml_file, warnings).each { |key| key_files[key] << relative }
      end
      yaml_files.size
    end

    def rank_keys(key_files, sort_order)
      ranked = key_files.map do |key, files|
        { key: key, file_count: files.size, files: files.sort }
      end
      ranked.sort_by { |entry| [(sort_order == :desc) ? -entry[:file_count] : entry[:file_count], entry[:key]] }
    end

    # Reads the environment hiera.yaml and returns an array of absolute paths
    # for every unique datadir declared (defaults + per-hierarchy overrides).
    def resolve_data_dirs(env_dir, hiera_yaml_path)
      hiera_config = YAML.safe_load_file(hiera_yaml_path) || {}
      default_dir  = hiera_config.dig('defaults', 'datadir') || 'data'
      hierarchy    = hiera_config['hierarchy'] || []

      all_dirs = [default_dir] + hierarchy_data_dirs(hierarchy)

      all_dirs.uniq.map { |d| File.expand_path(d, env_dir) }
    rescue Psych::SyntaxError => e
      raise "Failed to parse hiera.yaml: #{e.message}"
    end

    def hierarchy_data_dirs(hierarchy)
      hierarchy.filter_map { |level| level['datadir'] if level.is_a?(Hash) }
    end

    # Parses a single YAML data file and returns its top-level keys as strings.
    # Non-hash documents (bare strings, arrays, etc.) are silently skipped.
    def extract_keys(yaml_file, warnings)
      content = File.read(yaml_file, encoding: 'UTF-8', invalid: :replace)
      data    = YAML.safe_load(content)
      return [] unless data.is_a?(Hash)

      data.keys.map(&:to_s)
    rescue Psych::SyntaxError => e
      warnings << "YAML parse error in #{yaml_file}: #{e.message}"
      []
    rescue Errno::EACCES
      warnings << "Permission denied reading: #{yaml_file}"
      []
    end
  end
end
