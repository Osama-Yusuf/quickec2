# quickec2

Interactive CLI tool that deploys a fully configured AWS EC2 instance with VPC, networking, IAM, and optional S3 — in one command.

No Terraform, no CloudFormation, no YAML. Just answer prompts and get a running instance.

## Features

- **Interactive prompts** — guided setup with sensible defaults
- **Public & private modes** — public subnet with SSH or private subnet with NAT + SSM-only access
- **OS support** — Amazon Linux 2023, Ubuntu 22.04, Ubuntu 24.04
- **Software installer** — Docker, Git, Node.js, Python, Nginx, Certbot — auto-generates user-data per OS
- **Dry run** — preview every AWS command without creating anything
- **Cost estimate** — see monthly cost breakdown before deploying
- **Config replay** — save config, redeploy identical setups with `--config`
- **One-command cleanup** — tears down everything in the right order
- **State tracking** — all resource IDs saved to `resources.env` for reliable cleanup
- **Auto-tagging** — every resource tagged with project name, `CreatedBy=quickec2`, and timestamp

## Quick Start

```bash
git clone https://github.com/Osama-Yusuf/quickec2.git
cd quickec2
./quickec2.sh
```

## Prerequisites

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- AWS credentials configured (`aws configure`)
- [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) (for SSM connections)

## Usage

```bash
# Interactive deployment
./quickec2.sh

# Preview all commands without creating anything
./quickec2.sh --dry-run

# Use a specific AWS profile
./quickec2.sh --profile production

# Deploy from saved config (skip prompts)
./quickec2.sh --config quickec2.conf

# Check instance status
./quickec2.sh --status

# Connect to instance (auto-detects SSH or SSM)
./quickec2.sh --connect

# Tear down everything
./cleanup.sh
```

## CLI Flags

| Flag | Description |
|------|-------------|
| `--dry-run` | Full prompt flow, show config + cost estimate, print all AWS commands, exit |
| `--config <file>` | Load saved `quickec2.conf`, skip prompts |
| `--profile <name>` | Use a named AWS CLI profile |
| `--status` | Show instance state, IP, and SSM status |
| `--connect` | Auto-detect: SSM session (private) or SSH (public) |
| `--help` | Show usage |

## Interactive Prompts

| # | Prompt | Default | Options |
|---|--------|---------|---------|
| 1 | AWS profile | default | any configured profile |
| 2 | Project name | directory name | any |
| 3 | AWS Region | eu-west-1 | any |
| 4 | Network mode | private | public, private |
| 5 | IP type *(public only)* | auto | auto, elastic |
| 6 | Inbound ports *(public only)* | 22,80,443 | comma-separated |
| 7 | Instance type | t3.micro | t3.nano/micro/small/medium/large |
| 8 | Operating system | al2023 | al2023, ubuntu2204, ubuntu2404 |
| 9 | Volume size (GB) | 20 | number |
| 10 | Volume type | gp3 | gp3, gp2, io1 |
| 11 | SSH key pair *(public only)* | create | create, existing, none |
| 12 | Software | docker,git | docker, git, nodejs, python, nginx, certbot |
| 13 | Node.js version *(if selected)* | 20 | 18, 20, 22 |
| 14 | Python version *(if selected)* | 3.12 | 3.11, 3.12 |
| 15 | Create S3 bucket? | no | yes/no |
| 16 | Bucket name *(if yes)* | project-accountid | any |

## Network Modes

### Private (default)
- EC2 in private subnet, NAT Gateway for outbound
- No inbound access, SSM-only connections
- Security group: outbound 80/443 only
- ~$32/mo extra for NAT Gateway

### Public
- EC2 in public subnet with auto or elastic IP
- User-specified inbound ports (default: 22, 80, 443)
- SSH and/or SSM connections
- No NAT Gateway cost

## Cost Estimate

Displayed before deployment confirmation:

```
=== Estimated Monthly Cost ===
  EC2 (t3.micro)                 $7.59
  EBS (20GB gp3)                 $1.60
  NAT Gateway                   $32.40
  ─────────────────────────────────────
  TOTAL (approx)             $41.59/mo
```

## File Structure

```
quickec2/
├── quickec2.sh          # Main entry point
├── cleanup.sh           # Standalone cleanup
└── lib/
    ├── common.sh        # Colors, logging, aws_cmd wrapper, helpers
    ├── prompt.sh        # Interactive prompt functions
    ├── costs.sh         # Cost estimation
    ├── vpc.sh           # VPC, subnets, IGW, NAT, routes
    ├── ec2.sh           # IAM, security group, AMI, key pair, launch
    ├── s3.sh            # S3 bucket creation
    ├── software.sh      # User-data generator per OS
    └── cleanup.sh       # Teardown functions
```

## Generated Files

| File | Purpose | Persists |
|------|---------|----------|
| `resources.env` | All resource IDs for cleanup | Deleted after cleanup |
| `quickec2.conf` | Saved config for replay | Kept |
| `user-data.sh` | Generated bootstrap script | Deleted after cleanup |
| `*.pem` | SSH key (if created) | Deleted after cleanup |

## License

MIT
