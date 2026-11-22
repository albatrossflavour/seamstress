# frozen_string_literal: true

require 'puppetlabs_spec_helper/rake_tasks'
require 'puppet-strings/tasks' if Gem.loaded_specs.key?('puppet-strings')
require 'puppet-syntax/tasks/puppet-syntax'

PuppetLint.configuration.send(:disable_relative)
PuppetLint.configuration.fail_on_warnings = true
PuppetLint.configuration.ignore_paths = ['spec/**/*.pp', 'pkg/**/*.pp', 'vendor/**/*.pp']
