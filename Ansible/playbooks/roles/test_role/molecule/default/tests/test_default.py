import os
import testinfra.utils.ansible_runner

testinfra_hosts = testinfra.utils.ansible_runner.AnsibleRunner(
  os.environ['MOLECULE_INVENTORY_FILE']).get_hosts('all')


def test_user(host):
  user = host.user("www-data")
  assert user.exists


def test_nginx_is_installed(host):
  nginx = host.package("nginx")
  assert nginx.is_installed


def test_nginx_running_and_enabled(host):
  os = host.system_info.distribution
  if os == 'debian':
    nginx1 = host.service("nginx")
    assert nginx1.is_running
    assert nginx1.is_enabled


def test_nginx_is_listening(host):
  assert host.socket('tcp://127.0.0.1:80').is_listening
