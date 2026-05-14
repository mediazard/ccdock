# frozen_string_literal: true

require 'open3'

module Dock
  # Workspace creation and detection.
  #
  # Prefers `jj workspace add -r @` (inherits current working-copy state including
  # uncommitted edits). Falls back to `git worktree add` when jj is unavailable.
  # Detects pre-existing worktrees (created by Conductor or by hand) and skips
  # creation in that case.
  module Workspace
    module_function

    # @return [Boolean] true if path is already a jj workspace or git worktree
    def already_present?(path)
      return false unless File.directory?(path)

      File.directory?(File.join(path, '.jj')) || git_worktree?(path)
    end

    def create(path)
      if jj_available?
        # -r @ ensures the workspace inherits uncommitted file state from the
        # current working copy, not just the parent revision.
        run!('jj', 'workspace', 'add', path, '-r', '@')
      else
        run!('git', 'worktree', 'add', path)
      end
    end

    def forget(slug)
      return unless jj_available?

      # `jj workspace forget` is idempotent — silently no-ops if the workspace
      # is already forgotten or never existed.
      system('jj', 'workspace', 'forget', slug, out: File::NULL, err: File::NULL)
    end

    # Private

    def jj_available?
      system('which', 'jj', out: File::NULL, err: File::NULL)
    end
    private_class_method :jj_available?

    def git_worktree?(path)
      out, _err, status = Open3.capture3('git', '-C', path, 'rev-parse', '--git-common-dir')
      return false unless status.success?

      common = File.expand_path(out.strip, path)
      dir, _err, dir_status = Open3.capture3('git', '-C', path, 'rev-parse', '--git-dir')
      return false unless dir_status.success?

      git_dir = File.expand_path(dir.strip, path)
      common != git_dir
    rescue StandardError
      false
    end
    private_class_method :git_worktree?

    def run!(*cmd)
      raise WorkspaceError, "Command failed: #{cmd.join(' ')}" unless system(*cmd)
    end
    private_class_method :run!
  end
end
