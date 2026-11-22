# frozen_string_literal: true

require 'puppetlabs_spec_helper/module_spec_helper'
require 'rspec-puppet-facts'

RSpec.configure do |c|
  c.extend RspecPuppetFacts
  c.default_facts = { 'networking' => { 'fqdn' => 'docs.example.com' } }
  c.before { Puppet.settings[:strict] = :error }
end
