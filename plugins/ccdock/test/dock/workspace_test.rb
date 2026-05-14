# frozen_string_literal: true

require_relative '../test_helper'

class Dock::WorkspaceTest < Minitest::Test
  def test_already_present_true_for_jj_workspace
    Dir.mktmpdir('ccdock-test-jj-') do |dir|
      FileUtils.mkdir_p(File.join(dir, '.jj'))
      assert Dock::Workspace.already_present?(dir)
    end
  end

  def test_already_present_false_for_non_existent_dir
    refute Dock::Workspace.already_present?('/this/path/should/not/exist/at/all')
  end

  def test_already_present_false_for_empty_dir_without_jj_or_git
    Dir.mktmpdir('ccdock-test-empty-') do |dir|
      # Stub the private git_worktree? helper so we don't shell out to real git.
      Dock::Workspace.stubs(:git_worktree?).returns(false)
      refute Dock::Workspace.already_present?(dir)
    end
  end

  def test_already_present_true_when_git_worktree_detected
    Dir.mktmpdir('ccdock-test-gwt-') do |dir|
      Dock::Workspace.stubs(:git_worktree?).returns(true)
      assert Dock::Workspace.already_present?(dir)
    end
  end

  def test_already_present_returns_false_for_a_regular_file
    Tempfile.create('ccdock-test-file-') do |f|
      refute Dock::Workspace.already_present?(f.path)
    end
  end

  def test_create_uses_jj_when_available
    Dir.mktmpdir('ccdock-test-create-') do |dir|
      path = File.join(dir, 'ws-foo')
      Dock::Workspace.stubs(:jj_available?).returns(true)
      Dock::Workspace.expects(:system).with('jj', 'workspace', 'add', path, '-r', '@').returns(true)
      Dock::Workspace.create(path)
    end
  end

  def test_create_falls_back_to_git_worktree_when_jj_missing
    Dir.mktmpdir('ccdock-test-create-git-') do |dir|
      path = File.join(dir, 'ws-foo')
      Dock::Workspace.stubs(:jj_available?).returns(false)
      Dock::Workspace.expects(:system).with('git', 'worktree', 'add', path).returns(true)
      Dock::Workspace.create(path)
    end
  end

  def test_create_raises_when_underlying_command_fails
    Dir.mktmpdir('ccdock-test-create-fail-') do |dir|
      path = File.join(dir, 'ws-foo')
      Dock::Workspace.stubs(:jj_available?).returns(true)
      Dock::Workspace.stubs(:system).returns(false)
      assert_raises(Dock::WorkspaceError) { Dock::Workspace.create(path) }
    end
  end
end
