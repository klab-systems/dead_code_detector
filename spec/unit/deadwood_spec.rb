# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require_relative '../../files/deadwood'

RSpec.describe Deadwood do
  # Each example gets an isolated, temporary Puppet environment, removed afterward.
  let(:env_dir) { Dir.mktmpdir('deadwood-spec-') }

  after(:each) { FileUtils.remove_entry(env_dir) }

  # Fixtures are small files representing a control repo; no live Puppet services are used.
  def write_fixture(path, content)
    full_path = File.join(env_dir, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
    full_path
  end

  # These two checks run for each function, template, and file scanner.
  shared_examples 'an environment scanner' do
    # A nonexistent environment must raise an error rather than produce an empty report.
    it 'rejects missing environments' do
      expect { scanner.run(env_dir: File.join(env_dir, 'missing')) }
        .to raise_error(RuntimeError, %r{Environment directory not found})
    end

    # An existing environment without modules/ is also invalid.
    it 'rejects missing module directories' do
      empty_env = File.join(env_dir, 'empty')
      FileUtils.mkdir_p(empty_env)
      expect { scanner.run(env_dir: empty_env) }
        .to raise_error(RuntimeError, %r{modules/ directory not found})
    end
  end

  describe Deadwood::FunctionScanner do
    let(:scanner) { described_class.new }
    let(:modern_function) do
      {
        call_name: 'sample::modern',
        qualified_name: 'sample::modern',
        module_name: 'sample',
        source_file: File.join(env_dir, 'modules/sample/lib/puppet/functions/modern.rb'),
        type: 'ruby_modern',
      }
    end
    let(:fallback_function) do
      {
        call_name: 'fallback',
        qualified_name: 'sample::fallback',
        module_name: 'sample',
        source_file: File.join(env_dir, 'modules/sample/lib/puppet/parser/functions/fallback.rb'),
        type: 'ruby_legacy',
      }
    end

    let(:legacy_warning) do
      '2 legacy Ruby function(s) detected (type: ruby_legacy). ' \
        'Legacy function names are unnamespaced, which increases the risk of ' \
        'false negatives if the name is generic (e.g. "validate_string"). ' \
        'Review these results manually: fallback, legacy'
    end

    # Include all three function styles, an invalid declaration, and a legacy filename fallback.
    # Current text scanning counts declarations themselves as references for named functions.
    before :each do
      write_fixture('modules/sample/functions/native.pp', 'function sample::native() {}')
      write_fixture('modules/sample/functions/invalid.pp', '# no function declaration')
      write_fixture('modules/sample/lib/puppet/functions/modern.rb', "Puppet::Functions.create_function(:'sample::modern') {}")
      write_fixture('modules/sample/lib/puppet/parser/functions/legacy.rb', 'Puppet::Parser::Functions.newfunction(:legacy) {}')
      write_fixture('modules/sample/lib/puppet/parser/functions/fallback.rb', '# no declaration')
      write_fixture('modules/not_a_module', '')
    end

    include_examples 'an environment scanner'

    # Check the modern Ruby entry's names, module, source path, and serialized type.
    it 'preserves the report fields and function styles' do
      functions = scanner.run(env_dir: env_dir)[:used_functions]
      expect(functions).to include(modern_function)
    end

    # Without a declaration, the filename supplies the call name; the report adds its module.
    it 'keeps legacy fallback functions qualified in unused results' do
      expect(scanner.run(env_dir: env_dir)[:unused_functions]).to contain_exactly(fallback_function)
    end

    # A larger identifier containing "fallback" must not mark fallback() as used.
    it 'matches complete function names, not substrings' do
      write_fixture('manifests/site.pp', 'prefix_fallback_suffix()')
      expect(scanner.run(env_dir: env_dir)[:unused_functions].map { |entry| entry[:call_name] }).to eq(['fallback'])
    end

    # Calls under site/ count too, not just calls in module manifests.
    it 'recognizes calls in site manifests' do
      write_fixture('site/profile/init.pp', 'fallback()')
      expect(scanner.run(env_dir: env_dir)[:unused_functions]).to be_empty
    end

    # Check the warning text, legacy-function count, and alphabetical name order.
    it 'preserves the legacy warning and ordering' do
      expect(scanner.run(env_dir: env_dir)[:warnings]).to eq([legacy_warning])
    end
  end

  describe Deadwood::TemplateScanner do
    let(:scanner) { described_class.new }
    let(:expected_report) do
      {
        used_templates: [{
          reference: 'sample/nested/used.epp', module_name: 'sample', format: 'epp',
          source_file: File.join(env_dir, 'modules/sample/templates/nested/used.epp')
        }],
        unused_templates: [{
          reference: 'sample/unused.erb', module_name: 'sample', format: 'erb',
          source_file: File.join(env_dir, 'modules/sample/templates/unused.erb')
        }],
      }
    end

    include_examples 'an environment scanner'

    # A manifest references the nested EPP template; the unreferenced ERB remains unused.
    # Comparing the whole report also checks paths, format labels, and module references.
    it 'preserves used and unused template reports' do
      write_fixture('modules/sample/templates/nested/used.epp', 'used')
      write_fixture('modules/sample/templates/unused.erb', 'unused')
      write_fixture('manifests/site.pp', "epp('sample/nested/used.epp')")
      expect(scanner.run(env_dir: env_dir)).to eq(expected_report)
    end

    # A template mentioning its own reference must not be treated as an external caller.
    it 'does not count references in EPP templates as call sites' do
      write_fixture('modules/sample/templates/self.epp', 'sample/self.epp')
      expect(scanner.run(env_dir: env_dir)[:used_templates]).to be_empty
    end

    # Having no templates is valid and should return both result lists empty.
    it 'handles modules without templates' do
      FileUtils.mkdir_p(File.join(env_dir, 'modules/sample'))
      expect(scanner.run(env_dir: env_dir)).to eq(unused_templates: [], used_templates: [])
    end
  end

  describe Deadwood::FileScanner do
    let(:scanner) { described_class.new }
    let(:expected_report) do
      {
        used_files: [{
          uri: 'puppet:///modules/sample/nested/used.txt', module_name: 'sample',
          source_file: File.join(env_dir, 'modules/sample/files/nested/used.txt')
        }],
        unused_files: [{
          uri: 'puppet:///modules/sample/unused.txt', module_name: 'sample',
          source_file: File.join(env_dir, 'modules/sample/files/unused.txt')
        }],
      }
    end

    include_examples 'an environment scanner'

    # Only the file whose puppet:/// URI appears in a manifest is used.
    # The nested directory itself must not appear as a file in either result list.
    it 'preserves file reports and excludes directories' do
      write_fixture('modules/sample/files/nested/used.txt', 'used')
      write_fixture('modules/sample/files/unused.txt', 'unused')
      write_fixture('manifests/site.pp', "source => 'puppet:///modules/sample/nested/used.txt'")
      expect(scanner.run(env_dir: env_dir)).to eq(expected_report)
    end

    # ERB may generate manifests, so file source URIs inside ERB count as references.
    it 'recognizes file references in ERB templates' do
      write_fixture('modules/sample/files/used.txt', 'used')
      write_fixture('modules/sample/templates/site.erb', 'puppet:///modules/sample/used.txt')
      expect(scanner.run(env_dir: env_dir)[:unused_files]).to be_empty
    end

    # Preserve the scanner's policy of excluding EPP content from file-reference searches.
    it 'does not count references in EPP templates' do
      write_fixture('modules/sample/files/unused.txt', 'unused')
      write_fixture('modules/sample/templates/site.epp', 'puppet:///modules/sample/unused.txt')
      expect(scanner.run(env_dir: env_dir)[:used_files]).to be_empty
    end
  end

  describe Deadwood::TypeScanner do
    let(:expected_report) do
      {
        unused_defined_types: [{
          name: 'sample::unused', kind: 'defined_type', module_name: 'sample',
          source_file: File.join(env_dir, 'modules/sample/manifests/unused.pp')
        }],
        unused_custom_types: [{
          name: 'custom', kind: 'custom_type', module_name: 'sample',
          source_file: File.join(env_dir, 'modules/sample/lib/puppet/type/custom.rb')
        }],
      }
    end

    # Simulate PuppetDB reporting one applied defined type, without making an API call.
    # Only the other defined type and the native Ruby custom type should be reported unused.
    it 'preserves type classification and applied-type filtering' do
      write_fixture('modules/sample/manifests/unused.pp', 'define sample::unused { }')
      write_fixture('modules/sample/lib/puppet/type/custom.rb', "Puppet::Type.newtype('custom') {}")
      write_fixture('modules/sample/manifests/used.pp', 'define sample::used($value) {}')
      expect(described_class.new.run(modules_dir: File.join(env_dir, 'modules'), applied_resource_types: Set['sample::used'])).to eq(expected_report)
    end
  end

  describe 'declaration source encoding' do
    around :each do |example|
      original_encoding = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      example.run
    ensure
      Encoding.default_external = original_encoding
    end

    shared_examples 'a UTF-8 declaration reader' do |path, declaration, name|
      it 'discovers declarations with non-ASCII comments under an ASCII default encoding' do
        write_fixture(path, "# caf\u00e9\n#{declaration} # \u00a9\n")
        expect(discovered_names).to include(name)
      end

      it 'reports the source path and line for invalid UTF-8 instead of returning a partial report' do
        source = write_fixture(path, '# invalid: '.b + [255].pack('C') + "\n#{declaration}".b)
        expect { discovered_names }.to raise_error(RuntimeError, "Invalid UTF-8 in source file #{source}:1")
      end
    end

    context 'when discovering functions' do
      let(:discovered_names) do
        Deadwood::FunctionScanner::FunctionDiscovery.new.run(File.join(env_dir, 'modules')).map(&:call_name)
      end

      include_examples 'a UTF-8 declaration reader',
                       'modules/sample/functions/native.pp', 'function sample::native() {}', 'sample::native'
      include_examples 'a UTF-8 declaration reader',
                       'modules/sample/lib/puppet/functions/modern.rb', "Puppet::Functions.create_function(:'sample::modern') {}", 'sample::modern'
      include_examples 'a UTF-8 declaration reader',
                       'modules/sample/lib/puppet/parser/functions/legacy.rb', 'Puppet::Parser::Functions.newfunction(:legacy) {}', 'legacy'
    end

    context 'when discovering types' do
      let(:discovered_names) do
        report = Deadwood::TypeScanner.new.run(modules_dir: File.join(env_dir, 'modules'), applied_resource_types: Set.new)
        (report[:unused_defined_types] + report[:unused_custom_types]).map { |entry| entry[:name] }
      end

      include_examples 'a UTF-8 declaration reader',
                       'modules/sample/manifests/unused.pp', 'define sample::unused { }', 'sample::unused'
      include_examples 'a UTF-8 declaration reader',
                       'modules/sample/lib/puppet/type/custom.rb', "Puppet::Type.newtype('custom') {}", 'custom'
    end
  end

  describe Deadwood::HieraScanner do
    let(:scanner) { described_class.new }
    let(:expected_report) do
      {
        hiera_keys: [
          { key: 'alpha', file_count: 1, files: ['a.yaml'] },
          { key: 'beta', file_count: 1, files: ['b.yaml'] },
          { key: 'common', file_count: 2, files: ['a.yaml', 'b.yaml'] },
        ],
        data_dirs: ['data', 'extra', 'missing'].map { |dir| File.join(env_dir, dir) },
        total_keys: 3, total_files_scanned: 3,
        warnings: ["Data directory not found, skipping: #{File.join(env_dir, 'missing')}"]
      }
    end

    # Exercise default and extra data directories, a duplicate, a missing directory,
    # and a non-hash hierarchy entry. Array-only YAML counts as scanned but has no keys.
    before :each do
      write_fixture('hiera.yaml', {
        'defaults' => { 'datadir' => 'data' },
        'hierarchy' => [{ 'datadir' => 'extra' }, { 'datadir' => 'data' }, { 'datadir' => 'missing' }, 'ignored'],
      }.to_yaml)
      write_fixture('data/a.yaml', { 'common' => 1, 'alpha' => 2 }.to_yaml)
      write_fixture('extra/b.yaml', { 'common' => 3, 'beta' => 4 }.to_yaml)
      write_fixture('data/array.yaml', ['not a hash'].to_yaml)
    end

    # Check key counts, relative filenames, unique data directories, and the missing-dir warning.
    # The shared key appears twice; alpha and beta appear once and sort alphabetically.
    it 'preserves the full ascending report including missing-directory warnings' do
      expect(scanner.run(env_dir: env_dir)).to eq(expected_report)
    end

    # Descending order puts the most frequent key first without reversing alphabetical ties.
    it 'sorts descending by count and ascending by key for ties' do
      expect(scanner.run(env_dir: env_dir, sort_order: :desc)[:hiera_keys].map { |entry| entry[:key] }).to eq(['common', 'alpha', 'beta'])
    end

    # A broken data file still counts as scanned and yields a warning, not a fatal error.
    it 'counts malformed YAML files and reports their parse errors' do
      write_fixture('data/invalid.yaml', 'broken: [')
      expect(scanner.run(env_dir: env_dir)).to include(total_files_scanned: 4, warnings: include(%r{YAML parse error}))
    end

    # Unlike a broken data file, broken hiera.yaml is fatal: data directories cannot be resolved.
    it 'reports malformed hiera configuration' do
      write_fixture('hiera.yaml', 'broken: [')
      expect { scanner.run(env_dir: env_dir) }.to raise_error(RuntimeError, %r{Failed to parse hiera.yaml})
    end
  end
end
