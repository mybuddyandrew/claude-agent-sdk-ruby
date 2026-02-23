# frozen_string_literal: true

require_relative 'lib/claude_agent_sdk/version'

Gem::Specification.new do |spec|
  spec.name = 'claude-agent-sdk'
  spec.version = ClaudeAgentSDK::VERSION
  spec.authors = ['Community Contributors']
  spec.email = []

  spec.summary = 'Unofficial Ruby SDK for Claude Agent + Skein agent kernel'
  spec.description = 'Ruby SDK for Claude Code with Skein personal assistant agent kernel. ' \
                     'Supports bidirectional conversations, custom tools, hooks, memory, lessons, ' \
                     'task decomposition, and skill system.'
  spec.homepage = 'https://github.com/mybuddyandrew/claude-agent-sdk-ruby'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/mybuddyandrew/claude-agent-sdk-ruby'
  spec.metadata['changelog_uri'] = 'https://github.com/mybuddyandrew/claude-agent-sdk-ruby/blob/main/CHANGELOG.md'
  spec.metadata['documentation_uri'] = 'https://docs.anthropic.com/en/docs/claude-code/sdk'

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir['lib/**/*', 'README.md', 'LICENSE', 'CHANGELOG.md']
  spec.require_paths = ['lib']

  # Runtime dependencies — SDK
  spec.add_dependency 'async', '~> 2.0'
  spec.add_dependency 'mcp', '~> 0.4'

  # Runtime dependencies — Skein
  spec.add_dependency 'sqlite3', '~> 2.9'
  spec.add_dependency 'sqlite-vec', '~> 0.1'
  spec.add_dependency 'informers', '~> 1.2'
end
