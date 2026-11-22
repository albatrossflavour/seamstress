# frozen_string_literal: true

source ENV['GEM_SOURCE'] || 'https://rubygems.org'

puppet_version = ENV.fetch('PUPPET_GEM_VERSION', '~> 8.10')

group :development, :test do
  gem 'facterdb', '~> 3.1', require: false
  gem 'metadata-json-lint', '~> 4.0', require: false
  gem 'puppet', puppet_version, require: false
  gem 'puppetlabs_spec_helper', '~> 9.0', require: false
  gem 'puppet-lint', '~> 5.1', require: false
  gem 'puppet-strings', '~> 5.1', require: false
  gem 'puppet-syntax', '~> 4.1', require: false
  gem 'rspec-puppet', '~> 6.0', require: false
  gem 'rspec-puppet-facts', '~> 5.0', require: false
  gem 'rubocop', '~> 1.73', require: false
  gem 'rubocop-rspec', '~> 3.5', require: false
  # Former default gems that Puppet loads without declaring them.
  gem 'base64', require: false
  gem 'benchmark', require: false
  gem 'csv', require: false
  gem 'logger', require: false
  gem 'ostruct', require: false
  gem 'syslog', require: false
  # On Ruby 3.2 (Puppet 8's own Ruby) the newest jgrep that installs is 1.5.4,
  # which facterdb uses and which calls JSON.create_id=, removed in json 3.0.
  # jgrep 1.6.0 fixed that but needs Ruby 3.3.
  gem 'json', '< 3', require: false if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.3')
end
