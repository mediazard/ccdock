# frozen_string_literal: true

# Dock — parallel Docker workspaces for compose-based projects.
#
# Top-level autoloader. Each concern lives in its own file under lib/dock/.
# Adopting projects place a .dock.yml at their root; Dock::Config discovers it
# by walking up from cwd. No project name, host, or DB literal lives in this code.

module Dock
  Error = Class.new(StandardError)
  ConfigNotFoundError = Class.new(Error)
  ConfigInvalidError = Class.new(Error)
  WorkspaceError = Class.new(Error)
  CaddyError = Class.new(Error)
end

require_relative 'dock/version'
require_relative 'dock/config'
require_relative 'dock/slug'
require_relative 'dock/workspace'
require_relative 'dock/env_files'
require_relative 'dock/caddy'
require_relative 'dock/docker'
require_relative 'dock/fingerprint'
require_relative 'dock/inbox'
require_relative 'dock/commands/base'
require_relative 'dock/commands/start'
require_relative 'dock/commands/list'
require_relative 'dock/commands/destroy'
