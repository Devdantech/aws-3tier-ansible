# Ansible (Milestone 3)

Configures the private web instances over **SSM Session Manager**. No SSH, no key pair, and no inbound rules.

| Piece | What it does |
|---|---|
| `inventory/aws_ec2.yml` | `amazon.aws.aws_ec2` dynamic inventory: running instances tagged `Project=aws-3tier-ansible`, named by instance ID, grouped by `Role` tag (`Role=web` → `role_web`) |
| `group_vars/all.yml` | `amazon.aws.aws_ssm` connection. The S3 bucket it uses for file transfer comes from `ANSIBLE_SSM_BUCKET`, so the name stays out of the repo |
| `roles/nginx` | Installs nginx, adds a `/health` endpoint (for the M4 load balancer) and a landing page |
| `roles/cloudwatch_agent` | Installs the CloudWatch agent: `mem_used_percent` + root `disk used_percent` metrics, and nginx access/error logs shipped to `/aws-3tier-ansible/nginx/*` |
| `site.yml` | Runs both roles on `role_web`, then checks `/health` returns `ok` and the agent is `running` |

## Run it

Ansible can't be a control node on native Windows, so run it from WSL (Ubuntu):

```bash
./scripts/setup-ansible-wsl.sh            # once: ansible-core, boto3, amazon.aws, session-manager-plugin
export AWS_PROFILE=<your-profile> AWS_REGION=us-east-2
./scripts/04-run-ansible.sh               # inventory graph, then the playbook
```

`04-run-ansible.sh` reads the bucket name from the gitignored `state/ansible.env` (`SSM_BUCKET=...`). In WSL it reads the Windows `~/.aws` files directly, so credentials are never copied.
