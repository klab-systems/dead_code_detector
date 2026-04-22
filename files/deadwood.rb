# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'json'
require 'uri'
require 'set'
require 'time'

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
    EXCLUDED_NAMES = %w[class settings].freeze

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
      JSON.parse(body).map { |r| r['type'].downcase }.to_set
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
        meta:           meta,
        unused_classes: result[:unused_classes].sort,
        unused_modules: result[:unused_modules].map { |m|
          { name: m.name, unused_class_count: m.classes.size, classes: m.classes }
        }
      }
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
  #                  e.g.  Puppet::Functions.create_function(:'mymod::myfunc')
  #
  #   :ruby_legacy — Legacy Ruby API in modules/<mod>/lib/puppet/parser/functions/
  #                  e.g.  Puppet::Parser::Functions.newfunction(:myfunc, ...)
  #                  NOTE: legacy names are unnamespaced; false-positive risk is
  #                  higher for short generic names.
  # ===========================================================================
  class FunctionScanner
    FunctionDef = Struct.new(:call_name, :qualified_name, :module_name, :source_file, :type, keyword_init: true)

    # Returns a hash:
    #   {
    #     unused_functions: [ { call_name:, qualified_name:, module_name:, source_file:, type: }, ... ],
    #     used_functions:   [ ... ],
    #     warnings:         [ "..." ]
    #   }
    def run(env_dir:)
      raise "Environment directory not found: #{env_dir}" unless File.directory?(env_dir)

      modules_dir = File.join(env_dir, 'modules')
      raise "modules/ directory not found under #{env_dir}" unless File.directory?(modules_dir)

      functions   = discover_module_functions(modules_dir)
      call_sites  = find_call_sites(env_dir, functions.map(&:call_name).uniq)
      warnings    = build_warnings(functions)

      unused = functions.reject { |f| call_sites.key?(f.call_name) }
      used   = functions.select { |f| call_sites.key?(f.call_name) }

      {
        unused_functions: serialize(unused),
        used_functions:   serialize(used),
        warnings:         warnings
      }
    end

    private

    # -------------------------------------------------------------------------
    # Discovery
    # -------------------------------------------------------------------------

    def discover_module_functions(modules_dir)
      functions = []
      Dir.glob(File.join(modules_dir, '*')).each do |mod_path|
        next unless File.directory?(mod_path)

        mod_name = File.basename(mod_path)
        functions.concat(discover_pp_functions(mod_path, mod_name))
        functions.concat(discover_ruby_modern_functions(mod_path, mod_name))
        functions.concat(discover_ruby_legacy_functions(mod_path, mod_name))
      end
      functions.uniq(&:qualified_name).sort_by(&:qualified_name)
    end

    # modules/<mod>/functions/**/*.pp
    # Puppet-language functions; name is declared inline: function mod::name(...)
    def discover_pp_functions(mod_path, mod_name)
      Dir.glob(File.join(mod_path, 'functions', '**', '*.pp')).filter_map do |file|
        name = extract_pp_function_name(file)
        next unless name

        FunctionDef.new(
          call_name:      name,
          qualified_name: name,
          module_name:    mod_name,
          source_file:    file,
          type:           :pp_modern
        )
      end
    end

    # modules/<mod>/lib/puppet/functions/**/*.rb
    # Modern Ruby API: Puppet::Functions.create_function(:'mod::name')
    def discover_ruby_modern_functions(mod_path, mod_name)
      Dir.glob(File.join(mod_path, 'lib', 'puppet', 'functions', '**', '*.rb')).filter_map do |file|
        name = extract_ruby_modern_function_name(file)
        next unless name

        FunctionDef.new(
          call_name:      name,
          qualified_name: name,
          module_name:    mod_name,
          source_file:    file,
          type:           :ruby_modern
        )
      end
    end

    # modules/<mod>/lib/puppet/parser/functions/*.rb
    # Legacy Ruby API: Puppet::Parser::Functions.newfunction(:name, ...)
    # Names are unnamespaced in code; we qualify for grouping only.
    def discover_ruby_legacy_functions(mod_path, mod_name)
      Dir.glob(File.join(mod_path, 'lib', 'puppet', 'parser', 'functions', '*.rb')).filter_map do |file|
        name = extract_ruby_legacy_function_name(file)
        next unless name

        FunctionDef.new(
          call_name:      name,
          qualified_name: "#{mod_name}::#{name}",
          module_name:    mod_name,
          source_file:    file,
          type:           :ruby_legacy
        )
      end
    end

    # -------------------------------------------------------------------------
    # Name extraction
    # -------------------------------------------------------------------------

    def extract_pp_function_name(file)
      File.foreach(file) do |line|
        m = line.match(/^\s*function\s+([\w:]+)\s*[\(\|]/)
        return m[1].downcase if m
      end
      nil
    end

    def extract_ruby_modern_function_name(file)
      File.foreach(file) do |line|
        m = line.match(/create_function\s*\(\s*[:"']+([\w:]+)['":]?\s*\)/)
        return m[1].downcase if m
      end
      nil
    end

    def extract_ruby_legacy_function_name(file)
      File.foreach(file) do |line|
        m = line.match(/newfunction\s*\(\s*:(\w+)/)
        return m[1].downcase if m
      end
      # Fall back to filename if newfunction line can't be parsed
      File.basename(file, '.rb').downcase
    end

    # -------------------------------------------------------------------------
    # Call-site scanning
    # -------------------------------------------------------------------------

    # Returns a Hash of { call_name => [matched_file, ...] } for functions that
    # have at least one call site. Functions absent from the hash have no hits.
    def find_call_sites(env_dir, call_names)
      return {} if call_names.empty?

      source_files = collect_source_files(env_dir)
      hits         = Hash.new { |h, k| h[k] = [] }

      source_files.each do |src|
        begin
          content = File.read(src, encoding: 'UTF-8', invalid: :replace)
        rescue Errno::EACCES
          next
        end

        call_names.each do |name|
          # Match the function name not immediately preceded or followed by a
          # word character (avoids partial-name false positives).
          hits[name] << src if content.match?(/(?<!\w)#{Regexp.escape(name)}(?!\w)/)
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
        warnings << "#{legacy.size} legacy Ruby function(s) detected (type: ruby_legacy). " \
                    'Legacy function names are unnamespaced, which increases the risk of ' \
                    'false negatives if the name is generic (e.g. "validate_string"). ' \
                    'Review these results manually: ' + legacy.map(&:call_name).join(', ')
      end
      warnings
    end

    def serialize(functions)
      functions.map do |f|
        {
          call_name:      f.call_name,
          qualified_name: f.qualified_name,
          module_name:    f.module_name,
          source_file:    f.source_file,
          type:           f.type.to_s
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
        unused_custom_types:  serialize_types(unused_custom,  include_count: false)
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
        TypeDef.new(
          name:          name,
          pdb_type_name: pdb_name,
          module_name:   mod_name,
          source_file:   file,
          kind:          :defined_type
        )
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
        TypeDef.new(
          name:          name,
          pdb_type_name: pdb_name,
          module_name:   mod_name,
          source_file:   file,
          kind:          :custom_type
        )
      end
    end

    # -------------------------------------------------------------------------
    # Name extraction
    # -------------------------------------------------------------------------

    def extract_defined_type_name(file)
      File.foreach(file) do |line|
        m = line.match(/^\s*define\s+([\w:]+)\s*[\(\|{]?/)
        return m[1].downcase if m
      end
      nil
    end

    def extract_custom_type_name(file)
      File.foreach(file) do |line|
        # Puppet::Type.newtype(:name) or Puppet::Type.newtype('name')
        m = line.match(/newtype\s*\(\s*[:'"](\w+)/)
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
      type_count_pairs.map do |type_def, count|
        entry = {
          name:        type_def.name,
          kind:        type_def.kind.to_s,
          module_name: type_def.module_name,
          source_file: type_def.source_file
        }
        entry[:instance_count] = count if include_count
        entry
      end.sort_by { |e| e[:name] }
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
    TemplateDef = Struct.new(:reference, :module_name, :format, :source_file, keyword_init: true)

    # Returns a hash:
    #   {
    #     unused_templates: [ { reference:, module_name:, format:, source_file: }, ... ],
    #     used_templates:   [ ... ]
    #   }
    def run(env_dir:)
      raise "Environment directory not found: #{env_dir}" unless File.directory?(env_dir)

      modules_dir = File.join(env_dir, 'modules')
      raise "modules/ directory not found under #{env_dir}" unless File.directory?(modules_dir)

      templates   = discover_templates(modules_dir)
      call_sites  = find_call_sites(env_dir, templates.map(&:reference))

      unused = templates.reject { |t| call_sites.include?(t.reference) }
      used   = templates.select { |t| call_sites.include?(t.reference) }

      {
        unused_templates: serialize(unused),
        used_templates:   serialize(used)
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

        mod_name      = File.basename(mod_path)
        templates_dir = File.join(mod_path, 'templates')
        next unless File.directory?(templates_dir)

        Dir.glob(File.join(templates_dir, '**', '*.{epp,erb}')).each do |file|
          # Build the canonical module reference: '<mod>/<path/within/templates>'
          relative  = file.sub("#{templates_dir}/", '')
          format    = File.extname(file) == '.epp' ? :epp : :erb
          templates << TemplateDef.new(
            reference:   "#{mod_name}/#{relative}",
            module_name: mod_name,
            format:      format,
            source_file: file
          )
        end
      end
      templates.sort_by(&:reference)
    end

    # -------------------------------------------------------------------------
    # Call-site scanning
    # -------------------------------------------------------------------------

    # Returns a Set of template references that appear in at least one source file.
    def find_call_sites(env_dir, references)
      return Set.new if references.empty?

      source_files = collect_source_files(env_dir)
      found        = Set.new

      source_files.each do |src|
        begin
          content = File.read(src, encoding: 'UTF-8', invalid: :replace)
        rescue Errno::EACCES
          next
        end

        references.each do |ref|
          found.add(ref) if content.include?(ref)
        end
      end

      found
    end

    # All manifest, function, and library files that could contain template calls.
    # EPP template files themselves are excluded — an EPP cannot call itself.
    def collect_source_files(env_dir)
      patterns = [
        File.join(env_dir, 'manifests',   '**', '*.pp'),
        File.join(env_dir, 'modules',     '**', 'manifests',  '**', '*.pp'),
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
          reference:   t.reference,
          module_name: t.module_name,
          format:      t.format.to_s,
          source_file: t.source_file
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
    FileDef = Struct.new(:uri, :module_name, :source_file, keyword_init: true)

    # Returns a hash:
    #   {
    #     unused_files: [ { uri:, module_name:, source_file: }, ... ],
    #     used_files:   [ ... ]
    #   }
    def run(env_dir:)
      raise "Environment directory not found: #{env_dir}" unless File.directory?(env_dir)

      modules_dir = File.join(env_dir, 'modules')
      raise "modules/ directory not found under #{env_dir}" unless File.directory?(modules_dir)

      file_defs   = discover_module_files(modules_dir)
      used_uris   = find_call_sites(env_dir, file_defs.map(&:uri))

      unused = file_defs.reject { |f| used_uris.include?(f.uri) }
      used   = file_defs.select { |f| used_uris.include?(f.uri) }

      {
        unused_files: serialize(unused),
        used_files:   serialize(used)
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

        mod_name  = File.basename(mod_path)
        files_dir = File.join(mod_path, 'files')
        next unless File.directory?(files_dir)

        Dir.glob(File.join(files_dir, '**', '*')).each do |path|
          # Only report individual files — directories can be served recursively
          # and we cannot know statically whether a parent dir URI covers them.
          next if File.directory?(path)

          relative = path.sub("#{files_dir}/", '')
          file_defs << FileDef.new(
            uri:         "puppet:///modules/#{mod_name}/#{relative}",
            module_name: mod_name,
            source_file: path
          )
        end
      end
      file_defs.sort_by(&:uri)
    end

    # -------------------------------------------------------------------------
    # Call-site scanning
    # -------------------------------------------------------------------------

    # Returns a Set of URIs that appear in at least one source file.
    def find_call_sites(env_dir, uris)
      return Set.new if uris.empty?

      source_files = collect_source_files(env_dir)
      found        = Set.new

      source_files.each do |src|
        begin
          content = File.read(src, encoding: 'UTF-8', invalid: :replace)
        rescue Errno::EACCES
          next
        end

        uris.each do |uri|
          found.add(uri) if content.include?(uri)
        end
      end

      found
    end

    # All manifest, function, and library files that could contain file resource
    # source attributes. ERB templates are included as they can contain manifests
    # rendered dynamically. EPP templates are excluded — they cannot assign resources.
    def collect_source_files(env_dir)
      patterns = [
        File.join(env_dir, 'manifests',   '**', '*.pp'),
        File.join(env_dir, 'modules',     '**', 'manifests',  '**', '*.pp'),
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
          uri:         f.uri,
          module_name: f.module_name,
          source_file: f.source_file
        }
      end
    end
  end
end
