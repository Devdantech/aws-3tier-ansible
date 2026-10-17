# aws-3tier-ansible

A hands-on AWS networking lab built with Bash and the AWS CLI, with Ansible planned for the next stage. Region: us-east-2.

## What it builds

| Piece | Detail |
|---|---|
| VPC | 10.0.0.0/16, DNS hostnames on |
| Public subnets | 2, across 2 availability zones, auto-assign public IP |
| Private subnets | 2, across 2 availability zones |
| Internet gateway + public route table | default route to the internet gateway |
| NAT gateway + private route table | single NAT gateway in a public subnet |

Screenshots of the finished build are in `docs/`.

## Scripts

- `scripts/01-create-vpc.sh` creates the network above and saves each resource ID as it goes.
- `scripts/99-teardown.sh` deletes everything the build created.
- `scripts/lib.sh` holds shared settings (region, profile, project name).

Set `AWS_PROFILE` to your own CLI profile before running.

## Cost control

The NAT gateway bills by the hour. Run `scripts/99-teardown.sh` when you are done.

## Roadmap

- IAM instance role and locked-down S3 bucket
- EC2 instances configured with Ansible
- Load balancer, auto scaling, and CloudWatch alerts

## Layout

```
scripts/   Bash + AWS CLI
ansible/   inventory and roles (coming)
docs/      screenshots
state/     local resource IDs (gitignored)
```