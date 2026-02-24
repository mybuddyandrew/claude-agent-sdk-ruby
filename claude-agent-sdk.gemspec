# frozen_string_literal: true

require_relative 'lib/skein/version'

Gem::Specification.new do |spec|
  spec.name = 'skein'
  spec.version = Skein::VERSION
  spec.authors = ['Andrew Hodson']
  spec.email = []

  spec.summary = 'Skein personal assistant agent kernel with embedded Claude SDK compatibility'
  spec.description = 'Skein is a Ruby agent kernel for Claude Code with memory, lessons, task decomposition, ' \
                     'timers, and skills. It also bundles a ClaudeAgentSDK compatibility layer for existing integrations.'
  spec.homepage = 'https://github.com/mybuddyandrew/claude-agent-sdk-ruby'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 4.0.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/mybuddyandrew/claude-agent-sdk-ruby'
  spec.metadata['changelog_uri'] = 'https://github.com/mybuddyandrew/claude-agent-sdk-ruby/blob/main/CHANGELOG.md'
  spec.metadata['documentation_uri'] = 'https://github.com/mybuddyandrew/claude-agent-sdk-ruby#readme'

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir['lib/**/*', 'bin/*', 'docs/**/*.md', 'skills/**/*', 'README.md', 'LICENSE', 'CHANGELOG.md']
  spec.bindir = 'bin'
  spec.executables = ['skein']
  spec.require_paths = ['lib']

  # Runtime dependencies — SDK
  spec.add_dependency 'async', '~> 2.0'
  spec.add_dependency 'mcp', '~> 0.4'

  # Runtime dependencies — Skein
  spec.add_dependency 'sqlite3', '~> 2.9'
  spec.add_dependency 'sqlite-vec', '~> 0.1'
  spec.add_dependency 'informers', '~> 1.2'
end
