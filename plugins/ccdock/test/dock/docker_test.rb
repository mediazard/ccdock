# frozen_string_literal: true

require_relative '../test_helper'

class Dock::DockerTest < Minitest::Test
  # ---- volume_exists? / clone_volume ----------------------------------------

  def test_volume_exists_true_when_docker_returns_name
    Open3.expects(:capture3).with(
      'docker', 'volume', 'ls', '--format', '{{.Name}}', '--filter', 'name=^foo$'
    ).returns(["foo\n", '', mock_success_status])

    assert Dock::Docker.volume_exists?('foo')
  end

  def test_volume_exists_false_when_docker_returns_unrelated_name
    Open3.expects(:capture3).returns(["bar\n", '', mock_success_status])
    refute Dock::Docker.volume_exists?('foo')
  end

  def test_volume_exists_false_when_docker_command_fails
    Open3.expects(:capture3).returns(['', 'oops', mock_failure_status])
    refute Dock::Docker.volume_exists?('foo')
  end

  def test_try_clone_volume_returns_source_missing_when_source_absent
    Dock::Docker.stubs(:volume_exists?).with('src').returns(false)
    assert_equal :source_missing, Dock::Docker.try_clone_volume(from: 'src', to: 'dst')
  end

  def test_try_clone_volume_creates_target_and_copies_when_source_present
    Dock::Docker.stubs(:volume_exists?).with('src').returns(true)
    # volume create + docker run for the copy: two system calls in order.
    seq = sequence('clone')
    Dock::Docker.expects(:system).with(
      'docker', 'volume', 'create', 'dst', out: File::NULL, err: File::NULL
    ).in_sequence(seq).returns(true)
    Dock::Docker.expects(:system).with(
      'docker', 'run', '--rm',
      '-v', 'src:/from',
      '-v', 'dst:/to',
      'alpine', 'cp', '-a', '/from/.', '/to/',
      out: File::NULL, err: File::NULL
    ).in_sequence(seq).returns(true)

    assert_equal :cloned, Dock::Docker.try_clone_volume(from: 'src', to: 'dst')
  end

  def test_try_clone_volume_raises_when_copy_step_fails
    Dock::Docker.stubs(:volume_exists?).returns(true)
    Dock::Docker.stubs(:system).returns(true).then.returns(false)
    assert_raises(Dock::Error) { Dock::Docker.try_clone_volume(from: 'src', to: 'dst') }
  end

  # ---- project_volumes ------------------------------------------------------

  def test_project_volumes_filters_by_compose_project_label
    Open3.expects(:capture3).with(
      'docker', 'volume', 'ls', '--format', '{{.Name}}',
      '--filter', 'label=com.docker.compose.project=sc-1'
    ).returns(["sc-1_pg\nsc-1_redis\n\n", '', mock_success_status])

    assert_equal %w[sc-1_pg sc-1_redis], Dock::Docker.project_volumes(project: 'sc-1')
  end

  def test_project_volumes_returns_empty_when_docker_fails
    Open3.expects(:capture3).returns(['', 'err', mock_failure_status])
    assert_empty Dock::Docker.project_volumes(project: 'sc-1')
  end

  # ---- published_port -------------------------------------------------------

  def test_published_port_parses_host_port_from_compose_output
    Open3.expects(:capture3).with(
      'docker', 'compose', '-p', 'sc-1', 'port', 'web', '3000'
    ).returns(["0.0.0.0:49162\n", '', mock_success_status])

    assert_equal 49_162, Dock::Docker.published_port(project: 'sc-1', service: 'web', container_port: 3000)
  end

  def test_published_port_returns_nil_when_docker_fails
    Open3.expects(:capture3).returns(['', '', mock_failure_status])
    assert_nil Dock::Docker.published_port(project: 'sc-1', service: 'web', container_port: 3000)
  end

  # ---- list_projects --------------------------------------------------------

  def test_list_projects_parses_compose_ls_json
    json = [{ 'Name' => 'sc-1', 'Status' => 'running(4)' },
            { 'Name' => 'sc-2', 'Status' => 'running(4)' }].to_json
    Open3.expects(:capture3).with(
      'docker', 'compose', 'ls', '--format', 'json'
    ).returns([json, '', mock_success_status])

    projects = Dock::Docker.list_projects
    assert_equal 2, projects.size
    assert_equal 'sc-1', projects.first['Name']
  end

  def test_list_projects_returns_empty_on_invalid_json
    Open3.expects(:capture3).returns(['not json{', '', mock_success_status])
    assert_empty Dock::Docker.list_projects
  end

  def test_list_projects_returns_empty_on_docker_failure
    Open3.expects(:capture3).returns(['', 'err', mock_failure_status])
    assert_empty Dock::Docker.list_projects
  end

  # ---- service_status -------------------------------------------------------

  def test_service_status_returns_hash_for_object_response
    Open3.expects(:capture3).returns([{ 'Service' => 'web', 'Health' => 'healthy' }.to_json,
                                      '', mock_success_status])
    info = Dock::Docker.service_status(project: 'sc-1', service: 'web')
    assert_equal 'healthy', info['Health']
  end

  def test_service_status_returns_first_when_array_response
    json = [{ 'Service' => 'web', 'Health' => 'starting' }].to_json
    Open3.expects(:capture3).returns([json, '', mock_success_status])
    info = Dock::Docker.service_status(project: 'sc-1', service: 'web')
    assert_equal 'starting', info['Health']
  end

  def test_service_status_returns_nil_for_empty_output
    Open3.expects(:capture3).returns(["\n", '', mock_success_status])
    assert_nil Dock::Docker.service_status(project: 'sc-1', service: 'web')
  end

  # ---- compose --------------------------------------------------------------

  def test_compose_passes_env_and_args_to_docker
    captured_env = nil
    Dock::Docker.stubs(:system).with do |*args|
      captured_env = args.first if args.first.is_a?(Hash)
      true
    end.returns(true)

    Dock::Docker.compose(project: 'sc-1', args: %w[up -d web])
    refute_nil captured_env
    # Each problematic var should be present as nil (to clear inherited shell env).
    Dock::Docker::PROBLEMATIC_VARS.each do |var|
      assert captured_env.key?(var), "expected env to clear #{var}"
      assert_nil captured_env[var]
    end
  end

  def test_compose_raises_when_docker_command_fails
    Dock::Docker.stubs(:system).returns(false)
    assert_raises(Dock::Error) { Dock::Docker.compose(project: 'sc-1', args: %w[up -d]) }
  end

  private

  def mock_success_status
    stub(success?: true)
  end

  def mock_failure_status
    stub(success?: false)
  end
end
