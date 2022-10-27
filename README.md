# ansible-playbook-template

Ansible playbook template to be tested via pre-commit, GHA and Molecule.

## Prerequisites (Tested on)

- Python 3.9.14
- VagrantUp 2.3.2
- VirtualBox 7.0.2 r154219 (Qt5.15.2)

## CI/CD status

| Status |
| -------|
| ![Ansible-test GHA Workflow](https://github.com/andrey-asoskov/ansible-playbook-template/actions/workflows/ansible.yml/badge.svg) |

## Contents

- **.github/workflows/** - CI pipeline to test Ansible playbooks
- **Ansible/** - Ansible config
  - **collections** - Config to install Ansible collections
  - **molecule** - Config to install Molecule
  - **playbooks** - Ansible playbooks
    - **inventory** - Inventory config
    - **roles** - Roles config
      - **collect_logs**
      - **install_awscli2**
      - **install_docker**
      - **install_postgresql_client**
      - **install_python**
      - **setup_disks**
      - **update_packages**
    - **.ansible-lint**
  - **.flake8** - Flake8 Config
  - **.python-version** - Config for Python version
  - **requirements.txt** - Config to install Ansible
- **multipass** - Multipass config
- **.checkov.yaml** - Config for Checkov
- **.markdownlint.yaml**
- **.pre-commit-config.yaml**
- **.yamllint.yaml**

## Usage

### Install Ansible

```commandline
python3 -m pip install -r ./Ansible/requirements.txt
ansible-playbook --version
  
ansible-galaxy collection install -r ./Ansible/collections/requirements.yml
```

### Check syntax

```commandline
# Test playbook
ansible-playbook ./Ansible/playbooks/test_role.yaml --syntax-check

# Lint playbook
ansible-lint -s -c ./Ansible/playbooks/.ansible-lint ./Ansible/playbooks/test_role.yaml
```

### Test via Molecule

```commandline
# Install Molecule
python3 -m pip install -r ./Ansible/molecule/requirements.txt

# Test via Molecule
cd ./Ansible/playbooks/roles/test_role
molecule lint
molecule check
molecule create
molecule converge

# Destroy Molecule instance
molecule destroy
```

### Test via Multipass

```commandline
# Start multipass
multipass launch --name test1 -c 1 -m 4G  --cloud-init ./multipass/cloud-config.yaml 22.04 

# Test via multipass
ansible -m ping -i ',192.168.64.8' --user ansible all
ansible-playbook ./playbooks/test_role.yaml --user ansible -i ',192.168.64.8' -C
ansible-playbook ./playbooks/test_role.yaml --user ansible -i ',192.168.64.8'
```

### Run Ansible playbook

```commandline
# Test connection to AWS EC2
ansible -m ping \
-e ansible_connection=aws_ssm \
-e ansible_aws_ssm_timeout=600 \
-e ansible_aws_ssm_bucket_name=s3-bucket \
-i 'i-01fa72d3392fe2349,' \
all

# Test playbook with host connection
ansible-playbook ./Ansible/playbooks/test_role.yaml -C

# Run the playbook
ansible-playbook \
-e ansible_connection=aws_ssm \
-e ansible_aws_ssm_timeout=600 \
-e ansible_aws_ssm_bucket_name=s3-bucket \
-e app_version=32.0.11 \
-i "i-01fa72d3392fe2349," \
./test_role.yaml

# Run only specific tasks
ansible-playbook \
-e ansible_connection=aws_ssm \
-e ansible_aws_ssm_timeout=600 \
-e ansible_aws_ssm_bucket_name=s3-bucket \
-e app_version=32.0.11 \
-i "i-01fa72d3392fe2349," \
./test_role.yaml --tags "test"

# Transfer config to target machine - need to put a key and export AWS env vars
rsync -avh ./Ansible/ ubuntu@i-0a444bfdca7e77aad:~/Ansible/

# Run Ansible locally
ansible-playbook \
-c local \
-e app_version=32.0.11 \
-i "127.0.0.1," \
./forms.yaml
```

### Collect logs

Params can be configured in role's defaults file

```commandline
# Collect and download logs

<export AWS creds>

ansible-playbook  -e environment=prod -e app_version=32.0.17 ./collect_logs.yaml
```

### Execute commands on all hosts

```commandline
<export AWS creds>

ansible -m ping \
-e ansible_connection=aws_ssm \
-e ansible_aws_ssm_timeout=180 \
-e ansible_aws_ssm_bucket_name=s3-bucket \
aws_ec2

ansible -m command -a "" \
-e ansible_connection=aws_ssm \
-e ansible_aws_ssm_timeout=180 \
-e ansible_aws_ssm_bucket_name=s3-bucket \
aws_ec2

ansible -m shell -a "sed -i -e 's/max_log_file_action.*/max_log_file_action = rotate/g'  /etc/audit/auditd.conf; sed -i -e 's/space_left_action.*/space_left_action = rotate/g'  /etc/audit/auditd.conf; systemctl restart auditd" \
-e ansible_connection=aws_ssm \
-e ansible_aws_ssm_timeout=180 \
-e ansible_aws_ssm_bucket_name=s3-bucket \
i-05dd5e3dea61f16e5

ansible -m shell -a "sed -i -e 's/max_log_file_action.*/max_log_file_action = rotate/g'  /etc/audit/auditd.conf; sed -i -e 's/space_left_action.*/space_left_action = rotate/g'  /etc/audit/auditd.conf; systemctl restart auditd" \
-e ansible_connection=aws_ssm \
-e ansible_aws_ssm_timeout=180 \
-e ansible_aws_ssm_bucket_name=s3-bucket \
tag_component_forms

ansible -m shell -a "sed -i -e 's/max_log_file_action.*/max_log_file_action = rotate/g'  /etc/audit/auditd.conf; sed -i -e 's/space_left_action.*/space_left_action = rotate/g'  /etc/audit/auditd.conf; systemctl restart auditd" \
-e ansible_connection=aws_ssm \
-e ansible_aws_ssm_timeout=180 \
-e ansible_aws_ssm_bucket_name=s3-bucket \
tag_component_trainer
```

### Test GHA workflows locally

```commandline
# Test via Checkov
checkov -d . --config-file ./.checkov.yaml

# Test using medium image
act --rm -W ./.github/workflows/ansible.yml -P ubuntu-22.04=ghcr.io/catthehacker/ubuntu:act-22.04

# Test using full image 20.04
act --rm -W ./.github/workflows/ansible.yml -P ubuntu-22.04=catthehacker/ubuntu:full-20.04
```
